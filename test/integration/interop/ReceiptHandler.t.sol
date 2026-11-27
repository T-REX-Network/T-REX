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

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { TicketLib } from "contracts/compliance/modular/TicketLib.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { CappedRecipientModule, RecordingModule } from "test/integration/mocks/CapabilityModules.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev The receipt handler: home records what a receipt reports, and the terms check only decides whether the
///      away chain that sent it is also blocked. One hash per half tells the same receipt again from another one.
contract ReceiptHandlerTest is InteropSuiteTest {

    uint256 internal constant ALICE_AWAY_BALANCE = 1000;

    ERC7786GatewayMock internal polygonBridge;
    ERC7786GatewayMock internal optimismBridge;
    CappedRecipientModule internal capPerHolder;
    bytes internal aliceOnPolygon;
    bytes internal bobOnPolygon;

    function setUp() public override {
        super.setUp();
        polygonBridge = _newReceiptBridge(POLYGON);
        optimismBridge = _newReceiptBridge(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonBridge));
        _openEvmChain(token, OPTIMISM, address(optimismBridge));

        aliceOnPolygon =
            _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), ALICE_AWAY_BALANCE);
        bobOnPolygon = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        capPerHolder = CappedRecipientModule(
            address(
                new ModuleProxy(address(new CappedRecipientModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        vm.prank(deployer);
        boundCompliance.addModule(address(capPerHolder));

        vm.prank(agent);
        token.unpause();
    }

    /* ----- One hash per half ----- */

    /// @notice The same receipt again, under another receive id, changes nothing: it is consumed as a duplicate.
    function test_receiveReceipt_changesNothing_whenTheSameReceiptArrivesTwice() public {
        bytes32 ticketId = _ask(aliceOnPolygon, bobOnPolygon, 10, 50);
        MessageTypesLib.ReceiptMessage memory receipt = _settlement(ticketId, aliceOnPolygon, bobOnPolygon, 40);
        polygonBridge.relay(_liteSettles(polygonBridge, token, receipt));
        uint256 again = _liteSettles(polygonBridge, token, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptDuplicate(ticketId, polygon);
        polygonBridge.relay(again);

        assertTrue(token.messageReceived(address(polygonBridge), polygonBridge.receiveIdFor(again)), "consumed");
        assertEq(token.awayBalanceOf(bobOnPolygon), 40, "applied once");
        assertEq(token.awayBalanceOf(aliceOnPolygon), ALICE_AWAY_BALANCE - 40);
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "nothing blocked");
    }

    /// @notice Another receipt for a half that already has one is a bad receipt: refused, and its chain blocked.
    function test_receiveReceipt_blocksTheChain_whenAnotherReceiptComesForTheSameHalf() public {
        bytes32 ticketId = _ask(aliceOnPolygon, bobOnPolygon, 10, 50);
        polygonBridge.relay(_liteSettles(polygonBridge, token, _settlement(ticketId, aliceOnPolygon, bobOnPolygon, 40)));
        uint256 another = _liteSettles(polygonBridge, token, _settlement(ticketId, aliceOnPolygon, bobOnPolygon, 45));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptRefused(ticketId, polygon, 45, boundCompliance.ticketOf(ticketId).askBlockHash);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.AwayChainBlockStarted(polygon);
        polygonBridge.relay(another);

        assertEq(token.awayBalanceOf(bobOnPolygon), 40, "the first receipt stands");
        assertTrue(boundCompliance.isAwayChainBlocked(polygon));
    }

    /// @notice A receipt for a half home never sent is a bad receipt: home sends a ticket as the first half alone.
    function test_receiveReceipt_blocksTheChain_whenTheReceiptNamesAHalfHomeNeverSent() public {
        bytes32 ticketId = _ask(aliceOnPolygon, bobOnPolygon, 10, 50);
        MessageTypesLib.ReceiptMessage memory receipt = _settlement(ticketId, aliceOnPolygon, bobOnPolygon, 40);
        receipt.half = 1;
        uint256 index = _liteSettles(polygonBridge, token, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptRefused(ticketId, polygon, 40, receipt.askBlockHash);
        polygonBridge.relay(index);

        assertTrue(boundCompliance.isAwayChainBlocked(polygon));
        assertEq(token.awayBalanceOf(bobOnPolygon), 0, "nothing applied");
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Open));
    }

    /* ----- The chain of the half ----- */

    /// @notice A receipt binds to the chain of the half it answers: the honest receipt of the chain the ticket went
    ///         to is applied and blocks nothing, while the same receipt from another chain is a bad receipt that
    ///         blocks that chain alone.
    function test_receiveReceipt_doesNotBlockTheReceivingChain_forItsOwnHonestReceipt() public {
        bytes32 ticketId = _ask(aliceOnPolygon, bobOnPolygon, 10, 50);
        MessageTypesLib.ReceiptMessage memory receipt = _settlement(ticketId, aliceOnPolygon, bobOnPolygon, 40);
        uint256 fromAnotherChain = _liteSettles(optimismBridge, token, receipt);
        uint256 fromItsOwnChain = _liteSettles(polygonBridge, token, receipt);

        optimismBridge.relay(fromAnotherChain);
        assertTrue(boundCompliance.isAwayChainBlocked(optimism), "a chain the ticket never went to is blocked");

        polygonBridge.relay(fromItsOwnChain);

        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "the honest chain is not blocked");
        assertEq(token.awayBalanceOf(bobOnPolygon), 40);
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done));
    }

    /* ----- Broken terms ----- */

    /// @notice A receipt on home's own ask block hash that moved more than the copy allowed is applied as it
    ///         happened, because the away token's balances already moved, and then its away chain is blocked.
    function test_receiveReceipt_appliesTheBadReceiptAsItHappened_thenBlocksTheAwayChain() public {
        bytes32 ticketId = _ask(aliceOnPolygon, bobOnPolygon, 90, 100);
        uint256 movedAboveTheTicket = 120;
        uint256 index = _liteSettles(
            polygonBridge, token, _settlement(ticketId, aliceOnPolygon, bobOnPolygon, movedAboveTheTicket)
        );

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptApplied(ticketId, polygon, movedAboveTheTicket);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.AwayChainBlockStarted(polygon);
        polygonBridge.relay(index);

        assertEq(token.awayBalanceOf(bobOnPolygon), movedAboveTheTicket, "applied as it happened");
        assertEq(token.awayBalanceOf(aliceOnPolygon), ALICE_AWAY_BALANCE - movedAboveTheTicket);
        assertTrue(boundCompliance.isAwayChainBlocked(polygon), "the away chain is blocked");
        assertFalse(token.paused(), "the token keeps running");
    }

    /// @notice A receipt on home's own ask block hash that echoes other terms than home sent is a broken term too:
    ///         it blocks only the chain that sent it, never the other away chains, never the token.
    function test_receiveReceipt_blocksOnlyTheSendingChain_whenTheTermsAreBroken() public {
        bytes32 ticketId = _ask(aliceOnPolygon, bobOnPolygon, 10, 50);
        MessageTypesLib.ReceiptMessage memory receipt = _settlement(ticketId, aliceOnPolygon, bobOnPolygon, 40);
        receipt.seenValidUntil = receipt.seenValidUntil + 1;

        polygonBridge.relay(_liteSettles(polygonBridge, token, receipt));

        assertTrue(boundCompliance.isAwayChainBlocked(polygon), "the sending chain is blocked");
        assertFalse(boundCompliance.isAwayChainBlocked(optimism), "the other away chain is not");
        assertFalse(token.paused(), "nor is the token");
        assertEq(token.awayBalanceOf(bobOnPolygon), 40, "applied as it happened");
    }

    /// @notice An expired answer says the away token moved nothing: one that moved something is a bad receipt.
    function test_receiveReceipt_blocksTheChain_whenAnExpiredAnswerMovedSomething() public {
        bytes32 ticketId = _ask(aliceOnPolygon, bobOnPolygon, 10, 50);
        MessageTypesLib.ReceiptMessage memory receipt = _settlement(ticketId, aliceOnPolygon, bobOnPolygon, 40);
        receipt.answer = MessageTypesLib.ReceiptAnswer.Expired;

        polygonBridge.relay(_liteSettles(polygonBridge, token, receipt));

        assertTrue(boundCompliance.isAwayChainBlocked(polygon));
        assertEq(token.awayBalanceOf(bobOnPolygon), 0, "nothing applied");
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Open));
    }

    /* ----- Zero receipts ----- */

    /// @notice A zero receipt ends the ticket `Done` with nothing moved, and gives its reservation back.
    function test_receiveReceipt_endsTheTicketDone_whenTheReceiptIsZero() public {
        bytes32 ticketId = _ask(aliceOnPolygon, bobOnPolygon, 0, 50);
        assertEq(token.reservedOf(aliceOnPolygon), 50, "reserved while open");
        MessageTypesLib.ReceiptMessage memory receipt = _settlement(ticketId, aliceOnPolygon, bobOnPolygon, 0);
        receipt.answer = MessageTypesLib.ReceiptAnswer.Expired;

        uint256 index = _liteSettles(polygonBridge, token, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptApplied(ticketId, polygon, 0);
        polygonBridge.relay(index);

        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done));
        assertEq(boundCompliance.ticketOf(ticketId).moved, 0);
        assertEq(token.reservedOf(aliceOnPolygon), 0, "the reservation is released");
        assertEq(boundCompliance.pendingInOf(address(bobIdentity)), 0);
        assertEq(token.awayBalanceOf(aliceOnPolygon), ALICE_AWAY_BALANCE, "nothing moved");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
    }

    /// @notice A zero receipt is never a bad receipt: below the minimum, on terms home never sent, it still ends
    ///         the ticket with nothing moved and blocks nothing.
    function test_receiveReceipt_neverRefusesAZeroReceipt_whenItsTermsDiffer() public {
        bytes32 ticketId = _ask(aliceOnPolygon, bobOnPolygon, 10, 50);
        MessageTypesLib.ReceiptMessage memory receipt =
            _settlementUnder(ticketId, aliceOnPolygon, bobOnPolygon, 0, keccak256("a copy home never sent"));
        receipt.seenMax = 7;
        receipt.answer = MessageTypesLib.ReceiptAnswer.Expired;

        polygonBridge.relay(_liteSettles(polygonBridge, token, receipt));

        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "never a bad receipt");
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobOnPolygon), 0);
    }

    /// @notice A still open answer moves nothing and takes no half: the executed receipt that follows is applied.
    function test_receiveReceipt_changesNothing_whenTheAnswerIsStillOpen() public {
        bytes32 ticketId = _ask(aliceOnPolygon, bobOnPolygon, 10, 50);
        MessageTypesLib.ReceiptMessage memory stillOpen = _settlement(ticketId, aliceOnPolygon, bobOnPolygon, 0);
        stillOpen.answer = MessageTypesLib.ReceiptAnswer.StillOpen;

        polygonBridge.relay(_liteSettles(polygonBridge, token, stillOpen));
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Open));

        polygonBridge.relay(_liteSettles(polygonBridge, token, _settlement(ticketId, aliceOnPolygon, bobOnPolygon, 40)));

        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobOnPolygon), 40);
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
    }

    /* ----- Older terms ----- */

    /// @notice A deep home reorg drops the block that carried the ticket; the ask is mined again at the same height,
    ///         on the same parent, one second later. Same id, another valid until, so another ask block hash: the
    ///         away token's honest receipt is applied on the older terms it echoes, and its chain is not blocked.
    function test_receiveReceipt_appliesOnOlderTerms_whenASiblingBlockCarriedTheTicket() public {
        _setPerTicketCap(polygon, 50);
        bytes32 salt = _salt();
        uint256 snapshot = vm.snapshotState();
        vm.prank(address(aliceIdentity));
        bytes32 ticketId = boundCompliance.askToMove(aliceOnPolygon, bobOnPolygon, 10, 50, "", salt);
        ITickets.Ticket memory droppedCopy = boundCompliance.ticketOf(ticketId);
        vm.revertToState(snapshot);

        vm.warp(block.timestamp + 1);
        vm.prank(address(aliceIdentity));
        boundCompliance.askToMove(aliceOnPolygon, bobOnPolygon, 10, 50, "", salt);
        assertTrue(boundCompliance.ticketOf(ticketId).askBlockHash != droppedCopy.askBlockHash, "a sibling block");

        MessageTypesLib.ReceiptMessage memory receipt =
            _settlementUnder(ticketId, aliceOnPolygon, bobOnPolygon, 40, droppedCopy.askBlockHash);
        receipt.seenValidUntil = droppedCopy.validUntil;
        uint256 index = _liteSettles(polygonBridge, token, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptOnOlderTerms(ticketId, polygon, 50);
        polygonBridge.relay(index);

        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "the honest away chain is not blocked");
        assertEq(token.awayBalanceOf(bobOnPolygon), 40);
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done));
    }

    /// @notice Two copies from the same slot share block number, parent and time, and differ only in the terms
    ///         home narrowed: the copy home did not keep is told apart by its ask block hash, and applied on older
    ///         terms.
    function test_receiveReceipt_treatsACopyFromTheSameSlotAsOlderTerms_whenOnlyTheTermsDiffer() public {
        _setPerTicketCap(polygon, 50);
        uint64 validUntil = uint64(block.timestamp) + VALIDITY_WINDOW;
        bytes32 copyAtFifty = TicketLib.askBlockHashOf(50, validUntil);

        _setBobsCap(30);
        bytes32 ticketId = _ask(aliceOnPolygon, bobOnPolygon, 10, 50);
        ITickets.Ticket memory kept = boundCompliance.ticketOf(ticketId);
        assertEq(kept.amountMax, 30, "narrowed in this copy of the slot");
        assertEq(kept.validUntil, validUntil, "same slot, same valid until");
        assertTrue(kept.askBlockHash != copyAtFifty, "the terms tell the two copies apart");

        MessageTypesLib.ReceiptMessage memory receipt =
            _settlementUnder(ticketId, aliceOnPolygon, bobOnPolygon, 45, copyAtFifty);
        receipt.seenMax = 50;
        uint256 index = _liteSettles(polygonBridge, token, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptOnOlderTerms(ticketId, polygon, 50);
        polygonBridge.relay(index);

        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
        assertEq(token.awayBalanceOf(bobOnPolygon), 45);
    }

    /// @notice A home reorg drops the ask of 50 to 160 that home did not narrow, the away token executes that copy
    ///         for 160, and the ask is mined again under Bob's cap of 100. The receipt is applied on older terms:
    ///         Bob holds 160 under a cap of 100, home says so, and the honest away chain is not blocked.
    function test_receiveReceipt_appliesANarrowedTicketOnOlderTerms_whenTheAskWasMinedAgain() public {
        uint256 requestedMax = 160;
        uint256 bobCap = 100;
        bytes32 salt = _salt();
        uint64 droppedValidUntil = uint64(block.timestamp) + VALIDITY_WINDOW;
        bytes32 droppedAskBlockHash = TicketLib.askBlockHashOf(requestedMax, droppedValidUntil);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);

        _setBobsCap(bobCap);
        _setPerTicketCap(polygon, requestedMax);
        vm.prank(address(aliceIdentity));
        bytes32 ticketId = boundCompliance.askToMove(aliceOnPolygon, bobOnPolygon, 50, requestedMax, "", salt);
        assertEq(boundCompliance.ticketOf(ticketId).amountMax, bobCap, "the ask mined again is narrowed");

        MessageTypesLib.ReceiptMessage memory droppedCopyReceipt =
            _settlementUnder(ticketId, aliceOnPolygon, bobOnPolygon, requestedMax, droppedAskBlockHash);
        droppedCopyReceipt.seenMax = requestedMax;
        droppedCopyReceipt.seenValidUntil = droppedValidUntil;
        uint256 index = _liteSettles(polygonBridge, token, droppedCopyReceipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptOnOlderTerms(ticketId, polygon, requestedMax);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.MoveBreachedRule(ticketId, polygon, requestedMax);
        polygonBridge.relay(index);

        assertEq(token.awayBalanceOf(bobOnPolygon), requestedMax, "Bob holds 160 under a cap of 100");
        assertEq(token.awayBalanceOf(aliceOnPolygon), ALICE_AWAY_BALANCE - requestedMax);
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done));
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "the honest away chain is not blocked");
    }

    /// @notice Bob's cap and the away chain's per-ticket cap are both 1. Alice asks to move up to 2, home narrows to
    ///         1, and a hostile away token reports 2 on an invented ask block hash. The receipt is applied as it
    ///         happened, but its older terms pass the per-ticket cap: the away chain is blocked.
    function test_receiveReceipt_blocksTheChain_whenOlderTermsPassThePerTicketCap() public {
        _setPerTicketCap(polygon, 1);
        _setBobsCap(1);
        bytes32 ticketId = _ask(aliceOnPolygon, bobOnPolygon, 1, 2);
        assertEq(boundCompliance.ticketOf(ticketId).amountMax, 1, "narrowed to Bob's cap");

        MessageTypesLib.ReceiptMessage memory forged =
            _settlementUnder(ticketId, aliceOnPolygon, bobOnPolygon, 2, keccak256("an invented ask block"));
        forged.seenMax = 2;
        uint256 index = _liteSettles(polygonBridge, token, forged);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptOnOlderTerms(ticketId, polygon, 2);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.AwayChainBlockStarted(polygon);
        polygonBridge.relay(index);

        assertTrue(boundCompliance.isAwayChainBlocked(polygon), "older terms above the per-ticket cap block the chain");
        assertEq(token.awayBalanceOf(bobOnPolygon), 2, "applied as it happened");
    }

    /// @notice One deep reorg drops two asks to Bob, each of 0 to 80, written before Bob's cap of 100 was set; both
    ///         are mined again under the cap, at 80 and 20. The away token executed the dropped copies at 80 each:
    ///         Bob passes his cap by 60, which is what home narrowed away and no more than the per-ticket cap per
    ///         ticket, and nothing is blocked.
    function test_receiveReceipt_staysInsideTheBound_whenTwoTicketsAndOneDeepReorgPassACap() public {
        uint256 requestedMax = 80;
        uint256 perTicketCap = requestedMax;
        uint256 bobCap = 100;
        _setPerTicketCap(polygon, perTicketCap);
        uint64 droppedValidUntil = uint64(block.timestamp) + VALIDITY_WINDOW;
        bytes32 droppedAskBlockHash = TicketLib.askBlockHashOf(requestedMax, droppedValidUntil);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);

        _setBobsCap(bobCap);
        bytes32 first = _ask(aliceOnPolygon, bobOnPolygon, 0, requestedMax);
        bytes32 second = _ask(aliceOnPolygon, bobOnPolygon, 0, requestedMax);
        uint256 narrowedAway =
            2 * requestedMax - boundCompliance.ticketOf(first).amountMax - boundCompliance.ticketOf(second).amountMax;

        polygonBridge.relay(_liteSettles(polygonBridge, token, _droppedCopyReceipt(first, droppedAskBlockHash)));
        polygonBridge.relay(_liteSettles(polygonBridge, token, _droppedCopyReceipt(second, droppedAskBlockHash)));

        uint256 bobHolds = token.awayBalanceOf(bobOnPolygon);
        assertEq(bobHolds, 2 * requestedMax);
        assertEq(bobHolds - bobCap, narrowedAway, "the cap is passed by what home narrowed away, no more");
        assertLe(bobHolds, 2 * perTicketCap, "at most the per-ticket cap per ticket");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "within the bound, nothing is blocked");
    }

    /* ----- A receipt for an id home does not know ----- */

    /// @notice A receipt for an id home has no record of blocks nobody: it reverts and stays deliverable at the
    ///         bridge, and another holder's honest receipt from the same away chain still lands.
    function test_receiveReceipt_blocksNobody_whenTheTicketIsUnknown() public {
        bytes32 unknownId = keccak256("a ticket a home reorg dropped");
        uint256 unknownIndex = _liteSettles(
            polygonBridge, token, _settlementUnder(unknownId, aliceOnPolygon, bobOnPolygon, 95, keccak256("copy"))
        );

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptWithoutTicket(unknownId, polygon, aliceOnPolygon, bobOnPolygon, 95);
        polygonBridge.relay(unknownIndex);

        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "the away chain is not blocked");
        assertTrue(token.messageReceived(address(polygonBridge), polygonBridge.receiveIdFor(unknownIndex)), "consumed");
        assertEq(
            uint8(boundCompliance.statusOf(unknownId)), uint8(ITickets.TicketStatus.OnHold), "held, no destination"
        );

        bytes32 ticketId = _ask(aliceOnPolygon, bobOnPolygon, 10, 50);
        polygonBridge.relay(_liteSettles(polygonBridge, token, _settlement(ticketId, aliceOnPolygon, bobOnPolygon, 50)));

        assertEq(token.awayBalanceOf(bobOnPolygon), 50, "the honest receipt is applied");
        assertEq(uint8(boundCompliance.ticketOf(ticketId).status), uint8(ITickets.TicketStatus.Done));
    }

    /* ----- The per-ticket cap ----- */

    function test_setTicketLimits_setsBothCaps() public {
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.TicketLimitsSet(polygon, 70, 700);
        _setPerTicketCapAndWindowCap(polygon, 70, 700);

        ITickets.TicketLimits memory limits = boundCompliance.ticketLimitsOf(polygon);
        assertEq(limits.perTicketCap, 70);
        assertEq(limits.perWindowCap, 700);
        assertEq(boundCompliance.ticketLimitsOf(optimism).perTicketCap, TICKET_CAP, "per away chain");
    }

    /// @notice A ticket sent under the higher cap may still be executed until its valid until, and its honest
    ///         receipt would then pass the lower cap: the cap is lowered only once that time has come. Raising it is
    ///         never held back.
    function test_setTicketLimits_reverts_when_theCapIsLoweredBeforeTheLastTicketIsPastValidUntil() public {
        _setPerTicketCap(polygon, 50);
        bytes32 ticketId = _ask(aliceOnPolygon, bobOnPolygon, 10, 50);
        uint64 validUntil = boundCompliance.ticketOf(ticketId).validUntil;

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.PerTicketCapLoweredTooEarly.selector, polygon, validUntil));
        boundCompliance.setTicketLimits(polygon, 40, 40);

        _setPerTicketCap(polygon, 60);
        _setPerTicketCap(optimism, 0);

        vm.warp(validUntil);
        _setPerTicketCap(polygon, 40);
        assertEq(boundCompliance.ticketLimitsOf(polygon).perTicketCap, 40);
    }

    function test_setTicketLimits_reverts_when_theCallerHasNoRole() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        boundCompliance.setTicketLimits(polygon, 1, 1);
    }

    /* ----- Helpers ----- */

    function _ask(bytes memory from, bytes memory to, uint256 amountMin, uint256 requestedMax)
        private
        returns (bytes32)
    {
        return _requestValidation(address(aliceIdentity), from, to, amountMin, requestedMax);
    }

    /// @dev The receipt of a copy from a dropped home block that carried the whole request.
    function _droppedCopyReceipt(bytes32 ticketId, bytes32 droppedAskBlockHash)
        private
        view
        returns (MessageTypesLib.ReceiptMessage memory receipt)
    {
        uint256 requestedMax = boundCompliance.ticketOf(ticketId).requestedMax;
        receipt = _settlementUnder(ticketId, aliceOnPolygon, bobOnPolygon, requestedMax, droppedAskBlockHash);
        receipt.seenMax = requestedMax;
    }

    function _setPerTicketCap(bytes32 chainKey, uint256 perTicketCap) private {
        _setPerTicketCapAndWindowCap(chainKey, perTicketCap, perTicketCap);
    }

    function _setPerTicketCapAndWindowCap(bytes32 chainKey, uint256 perTicketCap, uint256 perWindowCap) private {
        vm.prank(deployer);
        boundCompliance.setTicketLimits(chainKey, perTicketCap, perWindowCap);
    }

    function _setBobsCap(uint256 cap) private {
        vm.prank(deployer);
        boundCompliance.callModuleFunction(abi.encodeCall(CappedRecipientModule.setCap, (cap)), address(capPerHolder));
    }

}
