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

import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { TicketLib } from "contracts/compliance/modular/TicketLib.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { ITREXRegistry } from "contracts/registry/interface/ITREXRegistry.sol";
import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { CappedRecipientModule, RecordingModule } from "test/integration/mocks/CapabilityModules.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev Issuance through the real messaging layer: which legs leave toward which chain, what they carry, how
///      the route is pinned, and how a closed chain or a pause stops everything before any write.
contract ValidationIssuanceTest is InteropSuiteTest {

    uint256 internal constant BALANCE = 100;

    ERC7786GatewayMock internal polygonGateway;
    ERC7786GatewayMock internal optimismGateway;
    bytes internal aliceSat;
    bytes internal bobSat;
    bytes internal bobOptimism;
    bytes internal nativeAlice;

    function setUp() public override {
        super.setUp();
        // Running: a paused token refuses every request (TokenPaused).
        vm.prank(agent);
        token.unpause();
        polygonGateway = _newTrustedGateway(POLYGON);
        optimismGateway = _newTrustedGateway(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        bobOptimism = _linkSatelliteWallet(bobIdentity, OPTIMISM, makeAccount("bobOnOptimism"));
        nativeAlice = InteroperableAddress.formatEvmV1(block.chainid, alice);
    }

    /* ----- Legs ----- */

    function test_requestTransferValidation_Success_WhenSameChainQueuesOneLeg() public {
        vm.warp(1_700_000_000);
        bytes32 id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 90);

        assertEq(polygonGateway.queueLength(), 1);
        assertEq(optimismGateway.queueLength(), 0);
        assertEq(polygonGateway.queuedMessage(0).recipient, token.peerFor(polygon));
        assertEq(token.pinnedRouteFor(id, polygon), address(polygonGateway));

        MessageTypesLib.TicketMessage memory sent = _decodeQueuedValidation(polygonGateway, 0);
        assertEq(sent.ticketId, id);
        assertEq(sent.from, aliceSat);
        assertEq(sent.to, bobSat);
        assertEq(sent.spender.length, 0);
        assertEq(sent.amountMin, 10);
        assertEq(sent.amountMax, 90);
        assertEq(sent.requestedMax, 90);
        assertEq(sent.token, address(token));
        assertEq(sent.validUntil, 1_700_000_000 + VALIDITY_WINDOW);
        assertEq(sent.askBlockHash, TicketLib.askBlockHashOf(90, 1_700_000_000 + VALIDITY_WINDOW));
        assertEq(boundCompliance.ticketOf(id).askBlockHash, sent.askBlockHash);
    }

    function test_requestTransferValidation_Success_WhenCrossChainQueuesOneLegPerChain() public {
        bytes32 id = _requestValidation(address(aliceIdentity), aliceSat, bobOptimism, 10, 90);

        assertEq(polygonGateway.queueLength(), 1);
        assertEq(optimismGateway.queueLength(), 1);
        assertEq(token.pinnedRouteFor(id, polygon), address(polygonGateway));
        assertEq(token.pinnedRouteFor(id, optimism), address(optimismGateway));

        MessageTypesLib.TicketMessage memory burnLeg = _decodeQueuedValidation(polygonGateway, 0);
        MessageTypesLib.TicketMessage memory mintLeg = _decodeQueuedValidation(optimismGateway, 0);
        assertEq(burnLeg.ticketId, id);
        assertEq(mintLeg.ticketId, id);
        assertEq(keccak256(abi.encode(burnLeg)), keccak256(abi.encode(mintLeg)), "one copy to both chains");

        ITickets.Ticket memory record = boundCompliance.ticketOf(id);
        assertEq(record.waitingEndsAt, record.validUntil + OPTIMISM_WINDOW);
        assertEq(record.fromChainKey, polygon);
        assertEq(record.toChainKey, optimism);
    }

    /// @notice Nothing would keep a native balance in place between issuance and settlement, so no satellite is
    ///         ever authorized to move one: a native position goes out through delegation-out, which burns first.
    function test_requestTransferValidation_RevertWhen_TheHolderSendsFromTheirNativeBalance() public {
        vm.prank(agent);
        token.mint(alice, 50);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SenderNotOnSatellite.selector, nativeAlice));
        boundCompliance.askToMove(nativeAlice, bobSat, 10, 200, "", _salt());

        assertEq(polygonGateway.queueLength(), 0);
        _assertNothingRecorded(nativeAlice, bobSat, "", 10, 200);
    }

    function test_requestTransferValidation_Success_WhenTheSpenderTravelsWithTheObject() public {
        bytes memory spender = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("operatorOnPolygon"));

        vm.prank(address(aliceIdentity));
        boundCompliance.askToMove(aliceSat, bobSat, 10, 90, spender, _salt());

        assertEq(_decodeQueuedValidation(polygonGateway, 0).spender, spender);
    }

    /// @notice One encoding per wallet on the wire too: a spender carrying trailing bytes never leaves.
    function test_requestTransferValidation_RevertWhen_TheSpenderIsNotCanonical() public {
        bytes memory spender =
            bytes.concat(InteroperableAddress.formatEvmV1(POLYGON, makeAddr("operatorOnPolygon")), hex"00");

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, spender));
        boundCompliance.askToMove(aliceSat, bobSat, 10, 90, spender, _salt());
    }

    function test_requestTransferValidation_Success_WhenSlippageIsCappedAtTheBalance() public {
        bytes32 id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 90, 110);

        MessageTypesLib.TicketMessage memory sent = _decodeQueuedValidation(polygonGateway, 0);
        assertEq(sent.amountMin, 90);
        assertEq(sent.amountMax, BALANCE);
        assertEq(boundCompliance.ticketOf(id).amountMax, BALANCE);
    }

    /* ----- Authorization ----- */

    function test_requestTransferValidation_Success_WhenAnAgentAsksForAnotherWallet() public {
        bytes32 id = _requestValidation(agent, aliceSat, bobSat, 10, 90);
        assertEq(id, _ticketId(aliceSat, bobSat, "", 10, 90, lastSalt));
    }

    function test_requestTransferValidation_RevertWhen_AStrangerAsks() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAuthorizedForWallet.selector, another, aliceSat));
        boundCompliance.askToMove(aliceSat, bobSat, 10, 90, "", _salt());
    }

    /* ----- Eligibility ----- */

    function test_requestTransferValidation_RevertWhen_TheRecipientWasRevoked() public {
        _revokeWallet(bobIdentity, bobSat);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnverifiedWallet.selector, bobSat));
        boundCompliance.askToMove(aliceSat, bobSat, 10, 90, "", _salt());
    }

    /// @notice A revoked sender keeps its position and may still move it out.
    function test_requestTransferValidation_Success_WhenTheSenderWasRevoked() public {
        _revokeWallet(aliceIdentity, aliceSat);

        bytes32 id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 90);
        assertEq(id, _ticketId(aliceSat, bobSat, "", 10, 90, lastSalt));
    }

    /* ----- Eligibility checks disabled ----- */

    function _disableEligibilityChecks() private {
        vm.prank(deployer);
        ITREXRegistry(address(token.identityRegistry())).disableEligibilityChecks();
    }

    /// @notice Disabling the claim checks does not disable the identity: a recipient the registry cannot
    ///         name gets no validation, native or satellite, so no position can land on identity zero.
    function test_requestTransferValidation_RevertWhen_ChecksAreDisabledAndTheRecipientHasNoIdentity() public {
        _disableEligibilityChecks();
        bytes memory nobodyNative = InteroperableAddress.formatEvmV1(block.chainid, david);
        bytes memory nobodySatellite = InteroperableAddress.formatEvmV1(POLYGON, david);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnverifiedWallet.selector, nobodyNative));
        boundCompliance.askToMove(aliceSat, nobodyNative, 10, 90, "", _salt());

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnverifiedWallet.selector, nobodySatellite));
        boundCompliance.askToMove(aliceSat, nobodySatellite, 10, 90, "", _salt());
    }

    /// @notice With the claim checks disabled a recipient with an identity is issued against the rules, the
    ///         cap narrows the range, and the settlement lands on that identity, not on identity zero.
    function test_requestTransferValidation_Success_WhenChecksAreDisabledTheCapStillApplies() public {
        _disableEligibilityChecks();
        CappedRecipientModule cappedRule = CappedRecipientModule(
            address(
                new ModuleProxy(address(new CappedRecipientModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        vm.startPrank(deployer);
        boundCompliance.addModule(address(cappedRule));
        boundCompliance.callModuleFunction(abi.encodeCall(CappedRecipientModule.setCap, (50)), address(cappedRule));
        vm.stopPrank();
        IComplianceLedger ledger = IComplianceLedger(address(boundCompliance));

        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 90);

        ITickets.Ticket memory validation = boundCompliance.ticketOf(ticketId);
        assertEq(validation.toIdentity, address(bobIdentity), "issued to bob's identity");
        assertEq(validation.amountMax, 50, "the cap narrowed the range");
        assertEq(ledger.pendingInOf(address(bobIdentity)), 50);
        assertEq(ledger.pendingInOf(address(0)), 0, "nothing promised to identity zero");

        polygonGateway.relay(_liteSettles(polygonGateway, token, _settlement(ticketId, aliceSat, bobSat, 40)));

        assertEq(ledger.positionOf(address(bobIdentity)), 40, "settled on bob's identity");
        assertEq(ledger.positionOf(address(0)), 0, "nothing on identity zero");
        assertEq(ledger.pendingInOf(address(bobIdentity)), 0, "the promise is released");
    }

    /* ----- Fail closed ----- */

    function test_requestTransferValidation_RevertWhen_TheGatewayIsNoLongerTrusted() public {
        trustedGatewayRegistry.setTrustedGateway(address(polygonGateway), false);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon));
        boundCompliance.askToMove(aliceSat, bobSat, 10, 90, "", _salt());

        _assertNothingRecorded(aliceSat, bobSat, "", 10, 90);
        assertEq(boundCompliance.ticketOf(bytes32(uint256(1))).askBlockHash, bytes32(0));
        assertEq(polygonGateway.queueLength(), 0);
    }

    /// @notice A cross-chain request with one chain closed sends nothing at all.
    function test_requestTransferValidation_RevertWhen_TheSecondLegHasNoRoute() public {
        vm.prank(deployer);
        token.setReceiptRoute(bytes2(0x0000), hex"0a", address(0));

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, optimism));
        boundCompliance.askToMove(aliceSat, bobOptimism, 10, 90, "", _salt());

        assertEq(polygonGateway.queueLength(), 0);
        _assertNothingRecorded(aliceSat, bobOptimism, "", 10, 90);
    }

    function test_requestTransferValidation_Success_WhenARouteSwitchPinsTheNewGatewayForNewIdsOnly() public {
        bytes32 first = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 90);
        ERC7786GatewayMock replacement = _newTrustedGateway(POLYGON);
        _openEvmChain(token, POLYGON, address(replacement));

        bytes32 second = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 90);

        assertEq(token.pinnedRouteFor(first, polygon), address(polygonGateway));
        assertEq(token.pinnedRouteFor(second, polygon), address(replacement));
        assertEq(replacement.queueLength(), 1);
    }

    function test_requestTransferValidation_Success_WhenPauseAndUnpauseRoundTrip() public {
        vm.prank(deployer);
        boundCompliance.setIssuancePaused(polygon, true);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationIssuancePaused.selector, polygon));
        boundCompliance.askToMove(aliceSat, bobSat, 10, 90, "", _salt());

        vm.prank(deployer);
        boundCompliance.setIssuancePaused(polygon, false);

        bytes32 id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 90);
        assertEq(id, _ticketId(aliceSat, bobSat, "", 10, 90, lastSalt));
        assertEq(polygonGateway.queueLength(), 1);
    }

    /// @notice A chain whose inbound is paused cannot report back, so nothing new is issued toward it; the other
    ///         chains are issued to as before.
    function test_requestTransferValidation_RevertWhen_AnInvolvedChainsInboundIsPaused() public {
        vm.prank(agent);
        token.setInboundPaused(optimism, true);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, optimism));
        boundCompliance.askToMove(aliceSat, bobOptimism, 10, 90, "", _salt());
        assertEq(polygonGateway.queueLength(), 0);
        assertEq(optimismGateway.queueLength(), 0);

        bytes32 id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 90);
        assertEq(id, _ticketId(aliceSat, bobSat, "", 10, 90, lastSalt));
        assertEq(polygonGateway.queueLength(), 1);
    }

    function test_requestTransferValidation_Success_WhenAnnouncingBeforeDispatching() public {
        vm.warp(1_700_000_000);
        bytes32 salt = _salt();
        bytes32 id = _ticketId(aliceSat, bobSat, "", 10, 90, salt);
        uint64 validUntil = 1_700_000_000 + VALIDITY_WINDOW;

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.TicketWritten(
            id, aliceSat, bobSat, "", 10, 90, 90, validUntil, TicketLib.askBlockHashOf(90, validUntil), salt
        );
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.HalfPinned(id, polygon, address(polygonGateway));
        vm.prank(address(aliceIdentity));
        boundCompliance.askToMove(aliceSat, bobSat, 10, 90, "", salt);
    }

}
