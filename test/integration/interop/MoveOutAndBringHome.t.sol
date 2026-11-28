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

import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { MovementKindLib } from "contracts/compliance/modular/MovementKindLib.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { TokenLedgerHarness } from "test/integration/helpers/TokenLedgerHarness.sol";
import { RecordingModule, TrackerOnlyModule } from "test/integration/mocks/CapabilityModules.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev The two movements that change where a position sits and never who owns it: a holder's home wallet moves out
///      to an away wallet, burned at home onto hold and minted away by a move out, and an agent brings an away
///      wallet's tokens home through a bring home ticket the away token answers with a receipt.
contract MoveOutAndBringHomeTest is InteropSuiteTest {

    uint256 internal constant MINTED = 1000;

    ERC7786GatewayMock polygonGateway;
    ERC7786GatewayMock optimismGateway;
    IComplianceLedger ledger;
    IERC3643IdentityRegistry registry;

    bytes aliceHome;
    bytes aliceSat;
    bytes aliceOptimism;
    bytes bobSat;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newReceiptBridge(POLYGON);
        optimismGateway = _newReceiptBridge(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        ledger = IComplianceLedger(address(boundCompliance));
        registry = token.identityRegistry();

        aliceHome = InteroperableAddress.formatEvmV1(block.chainid, alice);
        aliceSat = _linkSatelliteWallet(aliceIdentity, POLYGON, makeAccount("aliceOnPolygon"));
        aliceOptimism = _linkSatelliteWallet(aliceIdentity, OPTIMISM, makeAccount("aliceOnOptimism"));
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        vm.startPrank(agent);
        token.mint(alice, MINTED);
        token.unpause();
        vm.stopPrank();
    }

    /* ----- A home wallet moves out ----- */

    function test_askToMove_burnsAtHomeAndSendsTheMoveOut_whenTheSenderIsAHomeWallet() public {
        bytes32 salt = _salt();
        bytes32 id = _ticketId(aliceHome, aliceSat, "", 400, 400, salt);
        uint64 halfValidUntil = uint64(block.timestamp) + POLYGON_WINDOW;

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, address(0), 400);
        vm.expectEmit(true, true, true, true, address(boundCompliance));
        emit EventsLib.SecondHalfSent(id, 1, polygon, aliceSat, 400, halfValidUntil);
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ProtocolMessageSent(MessageTypesLib.Message.MOVE_OUT, polygon, polygonGateway.receiveIdFor(0));
        vm.prank(alice);
        boundCompliance.askToMove(aliceHome, aliceSat, 400, 400, "", salt);

        assertEq(token.balanceOf(alice), MINTED - 400, "burned at home");
        assertEq(token.onHoldOf(id), 400, "held for the move out");
        assertEq(token.awayBalanceOf(aliceSat), 0, "not minted away yet");
        assertEq(token.totalSupply(), MINTED, "the supply never moves");
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.OnHold));
        assertEq(ledger.positionOf(address(aliceIdentity)), MINTED, "location moved, ownership did not");

        MessageTypesLib.MoveOutMessage memory moveOut = _queuedMoveOut(0);
        assertEq(moveOut.ticketId, id);
        assertEq(moveOut.half, 1);
        assertEq(moveOut.toWallet, aliceSat);
        assertEq(moveOut.amount, 400);
        assertEq(moveOut.validUntil, halfValidUntil);
    }

    function test_receiveReceipt_landsTheMoveOut_andTellsTheTrackersOnce() public {
        TrackerOnlyModule tracker = _bindTracker();
        bytes32 id = _moveOut(400);

        polygonGateway.relay(_liteSettles(polygonGateway, token, _moveOutReceipt(id, 1, aliceSat, 400)));

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(aliceSat), 400);
        assertEq(token.onHoldOf(id), 0);
        assertEq(tracker.transferActionCalls(), 1, "told once, at Done");
        (,,,,,,, uint8 kind,,,) = tracker.lastContext();
        assertEq(kind, MovementKindLib.DELEGATION, "a home wallet's move out");
        _assertPartition();
    }

    /// @notice A home wallet moves its own tokens: its identity contract does not ask for it.
    function test_askToMove_reverts_when_theIdentityAsksForItsHomeWallet() public {
        vm.prank(address(aliceIdentity));
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.NotAuthorizedForWallet.selector, address(aliceIdentity), aliceHome)
        );
        boundCompliance.askToMove(aliceHome, aliceSat, 100, 100, "", _salt());
    }

    function test_askToMove_succeeds_whenAnAgentAsksForTheHomeWallet() public {
        vm.prank(agent);
        bytes32 id = boundCompliance.askToMove(aliceHome, aliceSat, 100, 100, "", _salt());

        assertEq(token.onHoldOf(id), 100);
    }

    /// @notice A funded wallet the registry now names for another identity cannot move: its balance would change
    ///         identity without any rule seeing it. It stays counted where it was until the registry agrees again.
    function test_askToMove_reverts_when_theFundedHomeWalletResolvesToAnotherIdentity() public {
        _swapStorageAnswer(alice, charlieIdentity);
        bytes memory charlieSat = _linkSatelliteWallet(charlieIdentity, POLYGON, makeAccount("charlieOnPolygon"));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.WalletBoundToAnotherIdentity.selector, alice, address(aliceIdentity))
        );
        boundCompliance.askToMove(aliceHome, charlieSat, 400, 400, "", _salt());

        assertEq(ledger.positionOf(address(aliceIdentity)), MINTED, "the position stays with the credited owner");
        assertEq(ledger.positionOf(address(charlieIdentity)), 0);
    }

    function test_askToMove_reverts_when_aStrangerAsksForAnotherHomeWallet() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAuthorizedForWallet.selector, bob, aliceHome));
        boundCompliance.askToMove(aliceHome, aliceSat, 1, 1, "", _salt());
    }

    function test_askToMove_reverts_when_theTokenIsPaused() public {
        vm.prank(agent);
        token.pause();

        vm.prank(alice);
        vm.expectRevert(ErrorsLib.TokenPaused.selector);
        boundCompliance.askToMove(aliceHome, aliceSat, 1, 1, "", _salt());
    }

    /// @notice No more supply goes to a chain whose receipts are suspect; nothing is burned.
    function test_askToMove_reverts_when_theReceiversChainIsBlocked() public {
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, polygon));
        boundCompliance.askToMove(aliceHome, aliceSat, 1, 1, "", _salt());

        assertEq(token.balanceOf(alice), MINTED);
    }

    function test_askToMove_reverts_when_theHomeWalletIsFrozen() public {
        vm.prank(agent);
        token.setAddressFrozen(alice, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.FrozenWallet.selector, alice));
        boundCompliance.askToMove(aliceHome, aliceSat, 1, 1, "", _salt());
    }

    function test_askToMove_reverts_when_theAmountIsBelowTheSmallestAmount() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BelowMinimumAmount.selector, 0, 1));
        boundCompliance.askToMove(aliceHome, aliceSat, 0, 0, "", _salt());
    }

    function test_askToMove_reverts_when_theRequestIsAboveTheUnfrozenBalance() public {
        vm.prank(agent);
        token.freezePartialTokens(alice, 700);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RequestAboveBalance.selector, aliceHome, 300, 400));
        boundCompliance.askToMove(aliceHome, aliceSat, 400, 400, "", _salt());
    }

    function test_askToMove_reverts_when_theAwayWalletIsNotLinked() public {
        bytes memory stray = _satelliteEnvelope(POLYGON, makeAddr("Stray"));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnverifiedWallet.selector, stray));
        boundCompliance.askToMove(aliceHome, stray, 1, 1, "", _salt());
    }

    /// @notice A revoked wallet still resolves to its identity, but it is not eligible for new activity.
    function test_askToMove_reverts_when_theAwayWalletWasRevoked() public {
        _revokeWallet(aliceIdentity, aliceSat);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnverifiedWallet.selector, aliceSat));
        boundCompliance.askToMove(aliceHome, aliceSat, 1, 1, "", _salt());
    }

    /// @notice A closed chain refuses the send, and the burn goes with it.
    function test_askToMove_reverts_when_theReceiversChainIsClosed() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, optimism));
        boundCompliance.askToMove(aliceHome, aliceOptimism, 100, 100, "", _salt());

        assertEq(token.balanceOf(alice), MINTED);
        assertEq(token.totalAwayBalance(), 0);
    }

    function test_askToMove_reverts_when_bothWalletsAreHomeWallets() public {
        bytes memory bobHome = InteroperableAddress.formatEvmV1(block.chainid, bob);

        vm.prank(alice);
        vm.expectRevert(ErrorsLib.NotACrossChainMove.selector);
        boundCompliance.askToMove(aliceHome, bobHome, 1, 1, "", _salt());
    }

    function test_askToMove_reverts_when_aHomeSenderNamesASpender() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SpenderNotAllowed.selector, address(0), alice, address(0), 1));
        boundCompliance.askToMove(aliceHome, aliceSat, 1, 1, bobSat, _salt());
    }

    /* ----- bringHome ----- */

    function test_bringHome_reservesTheAwayWalletAndSendsItsHalf() public {
        _moveOutAndLand(500);
        bytes32 salt = _salt();
        uint64 halfValidUntil = uint64(block.timestamp) + POLYGON_WINDOW;
        uint256 queued = polygonGateway.queueLength();

        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ProtocolMessageSent(
            MessageTypesLib.Message.BRING_HOME, polygon, polygonGateway.receiveIdFor(queued)
        );
        vm.prank(agent);
        bytes32 id = boundCompliance.bringHome(aliceSat, 200, alice, salt);

        ITickets.Ticket memory ticket = boundCompliance.ticketOf(id);
        assertEq(uint8(ticket.kind), uint8(ITickets.TicketKind.BRING_HOME));
        assertEq(uint8(ticket.status), uint8(ITickets.TicketStatus.Open));
        assertEq(ticket.homeWallet, alice);
        assertEq(token.reservedOf(aliceSat), 200, "reserved on the away wallet");
        assertEq(token.availableOf(aliceSat), 300);
        assertEq(token.balanceOf(alice), MINTED - 500, "a bring home moves nothing yet");

        MessageTypesLib.BringHomeMessage memory half = _queuedBringHome(queued);
        assertEq(half.ticketId, id);
        assertEq(half.half, 1);
        assertEq(half.wallet, aliceSat);
        assertEq(half.amount, 200);
        assertEq(half.validUntil, halfValidUntil);
    }

    function test_bringHome_reverts_when_theCallerIsNotAnAgent() public {
        _moveOutAndLand(500);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        boundCompliance.bringHome(aliceSat, 100, alice, _salt());
    }

    function test_bringHome_reverts_when_theAmountIsZero() public {
        _moveOutAndLand(500);

        vm.prank(agent);
        vm.expectRevert(ErrorsLib.ZeroValue.selector);
        boundCompliance.bringHome(aliceSat, 0, alice, _salt());
    }

    function test_bringHome_reverts_when_theHomeWalletIsZero() public {
        _moveOutAndLand(500);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WalletsNotLinked.selector, address(0), aliceSat));
        boundCompliance.bringHome(aliceSat, 100, address(0), _salt());
    }

    function test_bringHome_reverts_when_theAmountIsAboveTheFreeBalance() public {
        _moveOutAndLand(500);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RequestAboveBalance.selector, aliceSat, 500, 501));
        boundCompliance.bringHome(aliceSat, 501, alice, _salt());
    }

    /// @notice A ticket's reservation bounds a bring home: it never burns the tokens a ticket may move.
    function test_bringHome_reverts_when_aTicketReservedPartOfTheBalance() public {
        _moveOutAndLand(500);
        _requestValidation(address(aliceIdentity), aliceSat, bobSat, 1, 300);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RequestAboveBalance.selector, aliceSat, 200, 500));
        boundCompliance.bringHome(aliceSat, 500, alice, _salt());
    }

    /// @notice One bring home at a time per away wallet: the second waits for the first to be answered.
    function test_bringHome_reverts_when_theWalletAlreadyHasAnOpenBringHome() public {
        _moveOutAndLand(500);
        vm.prank(agent);
        bytes32 first = boundCompliance.bringHome(aliceSat, 100, alice, _salt());

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BringHomeAlreadyOpen.selector, keccak256(aliceSat), first));
        boundCompliance.bringHome(aliceSat, 100, alice, _salt());

        polygonGateway.relay(_liteSettles(polygonGateway, token, _bringHomeReceipt(first, 1, aliceSat, 100)));
        vm.prank(agent);
        boundCompliance.bringHome(aliceSat, 100, alice, _salt());
    }

    function test_bringHome_reverts_when_theWalletsAreNotLinked() public {
        _moveOutAndLand(500);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WalletsNotLinked.selector, bob, aliceSat));
        boundCompliance.bringHome(aliceSat, 100, bob, _salt());
    }

    function test_bringHome_reverts_when_theChainIsClosed() public {
        vm.prank(agent);
        TokenLedgerHarness(address(token)).ledgerMoveOut(alice, aliceOptimism, 100);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, optimism));
        boundCompliance.bringHome(aliceOptimism, 100, alice, _salt());

        assertEq(token.reservedOf(aliceOptimism), 0, "nothing reserved");
    }

    function test_bringHome_reverts_when_theTokenIsPaused() public {
        _moveOutAndLand(500);
        vm.prank(agent);
        token.pause();

        vm.prank(agent);
        vm.expectRevert(ErrorsLib.TokenPaused.selector);
        boundCompliance.bringHome(aliceSat, 100, alice, _salt());
    }

    function test_bringHome_reverts_when_theAwayChainIsBlocked() public {
        _moveOutAndLand(500);
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, polygon));
        boundCompliance.bringHome(aliceSat, 100, alice, _salt());
    }

    /* ----- The bring home's receipt ----- */

    function test_receiveReceipt_mintsAtHome_whenTheAwayTokenBurnedTheWholeAmount() public {
        TrackerOnlyModule tracker = _bindTracker();
        bytes32 id = _broughtHome(200);
        uint256 trackerCallsBefore = tracker.transferActionCalls();

        uint256 index = _liteSettles(polygonGateway, token, _bringHomeReceipt(id, 1, aliceSat, 200));
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(0), alice, 200);
        polygonGateway.relay(index);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.balanceOf(alice), MINTED - 300);
        assertEq(token.awayBalanceOf(aliceSat), 300);
        assertEq(token.reservedOf(aliceSat), 0, "the reservation is released");
        assertEq(ledger.positionOf(address(aliceIdentity)), MINTED, "ownership never moved");
        assertEq(tracker.transferActionCalls(), trackerCallsBefore + 1, "told once");
        (,,,,,,, uint8 kind,,,) = tracker.lastContext();
        assertEq(kind, MovementKindLib.RECALL);
        _assertPartition();
    }

    function test_receiveReceipt_mintsWhatWasBurned_whenTheAwayTokenHadLessToBurn() public {
        bytes32 id = _broughtHome(200);

        polygonGateway.relay(_liteSettles(polygonGateway, token, _bringHomeReceipt(id, 1, aliceSat, 150)));

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(boundCompliance.ticketOf(id).moved, 150);
        assertEq(token.balanceOf(alice), MINTED - 500 + 150);
        assertEq(token.awayBalanceOf(aliceSat), 350);
        _assertPartition();
    }

    function test_receiveReceipt_endsTheBringHomeWithNothingMoved_whenNothingWasBurned() public {
        bytes32 id = _broughtHome(200);

        polygonGateway.relay(_liteSettles(polygonGateway, token, _bringHomeReceipt(id, 1, aliceSat, 0)));

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(aliceSat), 500);
        assertEq(token.reservedOf(aliceSat), 0);
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
    }

    /// @notice The same receipt again changes nothing: the half has one receipt.
    function test_receiveReceipt_changesNothing_whenTheBringHomeReceiptIsDeliveredAgain() public {
        bytes32 id = _broughtHome(200);
        MessageTypesLib.ReceiptMessage memory receipt = _bringHomeReceipt(id, 1, aliceSat, 200);
        polygonGateway.relay(_liteSettles(polygonGateway, token, receipt));

        uint256 again = _liteSettles(polygonGateway, token, receipt);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptDuplicate(id, polygon);
        polygonGateway.relay(again);

        assertEq(token.balanceOf(alice), MINTED - 300, "minted once");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
    }

    function test_receiveReceipt_blocksTheChain_whenTheBringHomeBurnedMoreThanItsAmount() public {
        bytes32 id = _broughtHome(200);

        polygonGateway.relay(_liteSettles(polygonGateway, token, _bringHomeReceipt(id, 1, aliceSat, 201)));

        assertTrue(boundCompliance.isAwayChainBlocked(polygon));
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open), "the bring home stands");
        assertEq(token.balanceOf(alice), MINTED - 500, "nothing minted");
    }

    function test_receiveReceipt_blocksTheChain_whenTheBringHomeReceiptNamesAnotherWallet() public {
        bytes32 id = _broughtHome(200);

        polygonGateway.relay(_liteSettles(polygonGateway, token, _bringHomeReceipt(id, 1, bobSat, 200)));

        assertTrue(boundCompliance.isAwayChainBlocked(polygon));
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
    }

    function test_receiveReceipt_blocksTheOtherChain_whenTheBringHomeReceiptComesFromIt() public {
        bytes32 id = _broughtHome(200);
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

        optimismGateway.relay(_liteSettles(optimismGateway, token, _bringHomeReceipt(id, 1, aliceSat, 200)));

        assertTrue(boundCompliance.isAwayChainBlocked(optimism), "the chain that sent it is blocked");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
    }

    /// @notice A home wallet the registry no longer names for the identity does not take the bring home: what was
    ///         burned goes on hold and back to the away wallet by a move out.
    function test_receiveReceipt_sendsTheBurnedAmountBack_whenTheHomeWalletIsNoLongerTheIdentitys() public {
        bytes32 id = _broughtHome(200);
        _swapStorageAnswer(alice, charlieIdentity);
        uint256 index = _liteSettles(polygonGateway, token, _bringHomeReceipt(id, 1, aliceSat, 200));

        polygonGateway.relay(index);

        ITickets.Ticket memory ticket = boundCompliance.ticketOf(id);
        assertEq(uint8(ticket.status), uint8(ITickets.TicketStatus.OnHold), "on hold for its way back");
        assertEq(ticket.secondHalfToKey, keccak256(aliceSat), "back to the away wallet");
        assertEq(token.onHoldOf(id), 200);
        assertEq(token.balanceOf(alice), MINTED - 500, "nothing minted at home");
        MessageTypesLib.MoveOutMessage memory back = _queuedMoveOut(polygonGateway.queueLength() - 1);
        assertEq(back.toWallet, aliceSat);
        assertEq(back.amount, 200);
    }

    /* ----- Sending a half again ----- */

    function test_sendSecondHalf_reverts_beforeOneWaitingTimeAfterTheHalfsValidUntil() public {
        bytes32 id = _broughtHome(200);
        uint64 dueAt = boundCompliance.ticketOf(id).secondHalfValidUntil + POLYGON_WINDOW;
        vm.warp(dueAt - 1);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SendNotDue.selector, id, dueAt));
        boundCompliance.sendSecondHalf(id, aliceSat);
    }

    function test_sendSecondHalf_sendsTheBringHomeAgainByteForByte_atItsDueTime() public {
        bytes32 id = _broughtHome(200);
        uint256 firstSend = polygonGateway.queueLength() - 1;
        vm.warp(boundCompliance.ticketOf(id).secondHalfValidUntil + POLYGON_WINDOW);

        vm.prank(makeAddr("anyone"));
        boundCompliance.sendSecondHalf(id, aliceSat);

        uint256 secondSend = polygonGateway.queueLength() - 1;
        assertEq(
            polygonGateway.queuedMessage(secondSend).payload,
            polygonGateway.queuedMessage(firstSend).payload,
            "the same half, byte for byte"
        );
    }

    function test_sendSecondHalf_reverts_when_theWalletIsNotTheHalfs() public {
        bytes32 id = _broughtHome(200);
        vm.warp(boundCompliance.ticketOf(id).secondHalfValidUntil + POLYGON_WINDOW);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationBodyMismatch.selector, id));
        boundCompliance.sendSecondHalf(id, bobSat);
    }

    /// @notice A bring home is never cancelled: it ends on its receipt.
    function test_cancelTickets_reverts_forABringHome() public {
        bytes32 id = _broughtHome(200);
        vm.warp(block.timestamp + 10 * POLYGON_WINDOW);

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.TicketNotCancellable.selector, id, uint8(ITickets.TicketStatus.Open))
        );
        boundCompliance.cancelTickets(_ids(id));
    }

    /* ----- Helpers ----- */

    function _moveOut(uint256 amount) private returns (bytes32) {
        vm.prank(alice);
        return boundCompliance.askToMove(aliceHome, aliceSat, amount, amount, "", _salt());
    }

    /// @dev Alice moves `amount` out to her away wallet and its receipt lands.
    function _moveOutAndLand(uint256 amount) private returns (bytes32 id) {
        id = _moveOut(amount);
        polygonGateway.relay(_liteSettles(polygonGateway, token, _moveOutReceipt(id, 1, aliceSat, amount)));
    }

    /// @dev 500 moved out and landed, then a bring home of `amount` written and sent.
    function _broughtHome(uint256 amount) private returns (bytes32) {
        _moveOutAndLand(500);
        vm.prank(agent);
        return boundCompliance.bringHome(aliceSat, amount, alice, _salt());
    }

    /// @dev A move out's receipt: names the minted wallet only.
    function _moveOutReceipt(bytes32 ticketId, uint8 half, bytes memory toWallet, uint256 amount)
        private
        pure
        returns (MessageTypesLib.ReceiptMessage memory)
    {
        return MessageTypesLib.ReceiptMessage({
            ticketId: ticketId,
            from: "",
            to: toWallet,
            amount: amount,
            askBlockHash: bytes32(0),
            seenMax: 0,
            seenValidUntil: 0,
            half: half,
            answer: MessageTypesLib.ReceiptAnswer.Executed
        });
    }

    /// @dev A bring home's receipt: names the burned wallet only.
    function _bringHomeReceipt(bytes32 ticketId, uint8 half, bytes memory burnedWallet, uint256 burned)
        private
        pure
        returns (MessageTypesLib.ReceiptMessage memory)
    {
        return MessageTypesLib.ReceiptMessage({
            ticketId: ticketId,
            from: burnedWallet,
            to: "",
            amount: burned,
            askBlockHash: bytes32(0),
            seenMax: 0,
            seenValidUntil: 0,
            half: half,
            answer: MessageTypesLib.ReceiptAnswer.Executed
        });
    }

    function _queuedMoveOut(uint256 index) private view returns (MessageTypesLib.MoveOutMessage memory) {
        (MessageTypesLib.Message messageType, bytes memory body) =
            MessageTypesLib.decode(polygonGateway.queuedMessage(index).payload);
        assertEq(uint8(messageType), uint8(MessageTypesLib.Message.MOVE_OUT));
        return MessageTypesLib.decodeMintInstruction(body);
    }

    function _queuedBringHome(uint256 index) private view returns (MessageTypesLib.BringHomeMessage memory) {
        (MessageTypesLib.Message messageType, bytes memory body) =
            MessageTypesLib.decode(polygonGateway.queuedMessage(index).payload);
        assertEq(uint8(messageType), uint8(MessageTypesLib.Message.BRING_HOME));
        return MessageTypesLib.decodeBringHome(body);
    }

    /// @dev Binds a tracker before any ticket is open: modules change only while nothing is reserved.
    function _bindTracker() private returns (TrackerOnlyModule tracker) {
        tracker = TrackerOnlyModule(
            address(new ModuleProxy(address(new TrackerOnlyModule()), abi.encodeCall(RecordingModule.initialize, ())))
        );
        vm.prank(deployer);
        boundCompliance.addModule(address(tracker));
    }

    function _ids(bytes32 ticketId) private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = ticketId;
    }

    /// @dev Registry writes never relink a wallet, so a relink is simulated as the owner swapping the registry's
    ///  storage for one that binds `wallet` to `identity`, and the factory not knowing the wallet.
    function _swapStorageAnswer(address wallet, IIdentity identity) private {
        vm.mockCall(
            address(idFactory),
            abi.encodeWithSelector(
                idFactory.getIdentity.selector, InteroperableAddress.formatEvmV1(block.chainid, wallet)
            ),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(idFactory),
            abi.encodeWithSelector(
                idFactory.getIdentityIncludingRevoked.selector, InteroperableAddress.formatEvmV1(block.chainid, wallet)
            ),
            abi.encode(address(0), IIdentityFactory.AccountStatus.None)
        );
        vm.mockCall(
            address(registry.identityStorage()),
            abi.encodeCall(registry.identityStorage().storedIdentity, (wallet)),
            abi.encode(address(identity))
        );
    }

    function _assertPartition() private view {
        uint256 away = token.awayBalanceOf(aliceSat) + token.awayBalanceOf(bobSat) + token.awayBalanceOf(aliceOptimism)
            + token.totalOnHold();
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + away, MINTED, "buckets do not sum to the supply");
        assertEq(token.totalSupply(), MINTED, "the supply moved");
        assertEq(token.totalAwayBalance(), away, "totalAwayBalance drifted");
    }

}
