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

import { Vm } from "@forge-std/Vm.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ModularComplianceBaseUnitTest } from "./helpers/ModularComplianceBaseUnitTest.t.sol";
import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { MovementKindLib } from "contracts/compliance/modular/MovementKindLib.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "contracts/libraries/WalletKeyLib.sol";
import { IToken } from "contracts/token/IToken.sol";
import { Token } from "contracts/token/Token.sol";
import {
    CappedRecipientModule,
    RecordingModule,
    RuleOnlyModule,
    TrackerOnlyModule
} from "test/integration/mocks/CapabilityModules.sol";
import { TokenReservationStub } from "test/unit/compliance/helpers/TokenReservationStub.sol";

contract TicketsSettlementUnitTest is ModularComplianceBaseUnitTest {

    uint256 internal constant POLYGON = 137;
    uint256 internal constant OPTIMISM = 10;
    uint64 internal constant TICKET_ROUTE_WINDOW = 15 minutes;
    /// @dev Every ticket here travels the receipt route: the mocked token has no ticket bridge.
    uint64 internal constant VALIDITY_WINDOW = 25 minutes;
    uint64 internal constant POLYGON_WINDOW = 95 minutes;
    uint64 internal constant OPTIMISM_WINDOW = 100 minutes;
    uint256 internal constant ISSUED_AT = 1_700_000_000;
    uint256 internal constant BRIDGED_BALANCE = 100;

    /// @dev The receipt bridge and the peer the token reports a receipt was delivered by.
    address internal constant BRIDGE = address(0xB41D6E);
    bytes32 internal constant PEER_KEY = keccak256("the token's peer on the away chain");

    bytes32 internal polygon = _evmChainKey(POLYGON);
    bytes32 internal optimism = _evmChainKey(OPTIMISM);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal aliceIdentity = makeAddr("AliceIdentity");
    address internal bobIdentity = makeAddr("BobIdentity");
    address internal aliceId;
    address internal bobId;
    bytes internal fromSat;
    bytes internal toSat;
    bytes internal nativeBob;
    bytes internal carolSat;

    function setUp() public override {
        super.setUp();
        fromSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("aliceOnPolygon"));
        toSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("bobOnPolygon"));
        nativeBob = InteroperableAddress.formatEvmV1(block.chainid, bob);
        carolSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("carolOnPolygon"));
        aliceId = aliceIdentity;
        bobId = bobIdentity;

        mc.setValidityWindows(TICKET_ROUTE_WINDOW, VALIDITY_WINDOW);
        mc.setAskLimits(
            ITickets.AskLimits({
                openTicketsPerIdentity: 100, asksPerIdentityPerWindow: 1000, askWindow: 1 days, smallestAmount: 1
            })
        );
        mc.setWaitingTime(polygon, POLYGON_WINDOW);
        mc.setWaitingTime(optimism, OPTIMISM_WINDOW);

        vm.mockCall(token, abi.encodeWithSignature("identityRegistry()"), abi.encode(registry));
        // The wallet's room lives on the token now, so the mocked token address gets a stub with real
        // arithmetic for those few selectors; `vm.mockCall` still wins for everything mocked explicitly.
        vm.etch(token, address(new TokenReservationStub()).code);
        TokenReservationStub(token).setBridgedBalance(fromSat, BRIDGED_BALANCE);
        // Both away chains have their receipt route open on the token, so a ticket toward them may be cancelled.
        TokenReservationStub(token).openReceiptRoute(polygon, makeAddr("polygonReceiptBridge"));
        TokenReservationStub(token).openReceiptRoute(optimism, makeAddr("optimismReceiptBridge"));
        _bind(fromSat, aliceIdentity);
        _bind(nativeBob, bobIdentity);
        // A settlement to a native wallet resolves its owner again through the registry's native lookup.
        vm.mockCall(registry, abi.encodeWithSignature("identity(address)", bob), abi.encode(bobIdentity));
        _bind(toSat, bobIdentity);

        vm.warp(ISSUED_AT);
    }

    /* ----- Access ----- */

    function test_handleSettlement_RevertWhen_CallerIsNotTheBoundToken() public {
        bytes32 id = _issue();

        vm.prank(stranger);
        vm.expectRevert(ErrorsLib.AddressNotATokenBoundToComplianceContract.selector);
        mc.receiveReceipt(polygon, BRIDGE, PEER_KEY, _leg(id, fromSat, toSat, 50));
    }

    /* ----- Leg matching: a leg outside the issued terms is consumed with a verdict, never left deliverable ----- */

    /// @notice Wrong or missing wallets under the issued ask block hash: the Lite broke rule 6 on the body it was sent.
    ///         Rejected, the chain paused, the validation untouched.
    function test_handleSettlement_Success_WhenAWalletIsMissingOrForeign() public {
        bytes32 id = _issue();

        vm.startPrank(token);
        _assertRejected(id, polygon, _leg(id, fromSat, "", 50));
        _assertRejected(id, polygon, _leg(id, "", toSat, 50));
        _assertRejected(id, polygon, _leg(id, fromSat, carolSat, 50));
        _assertRejected(id, polygon, _leg(id, carolSat, toSat, 50));
        vm.stopPrank();

        _assertUntouched(id);
    }

    function test_handleSettlement_Success_WhenTheOriginIsNotARecordedChain() public {
        bytes32 id = _issue();

        vm.prank(token);
        _assertRejected(id, optimism, _leg(id, fromSat, toSat, 50));

        _assertUntouched(id);
    }

    /// @notice An amount outside the range of home's own copy breaks its terms: applied as it happened, and the
    ///         chain that sent it is to be blocked.
    function test_handleSettlement_Success_WhenAmountIsOutsideTheBounds() public {
        _track();
        bytes32 id = _issue();

        vm.expectCall(token, abi.encodeCall(IToken.finishMove, (fromSat, toSat, 9, id)), 1);
        vm.prank(token);
        mc.receiveReceipt(polygon, BRIDGE, PEER_KEY, _leg(id, fromSat, toSat, 9));

        assertTrue(mc.isAwayChainBlocked(polygon), "the away chain is blocked");
        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(mc.ticketOf(id).moved, 9);
        assertEq(mc.positionOf(bobId), 9);
    }

    /// @notice A receipt under another ask block hash answers a copy from a dropped home block. Above what that copy
    ///         allowed it breaks its terms: applied as it happened, the reservation released, the chain to be blocked.
    function test_handleSettlement_Success_WhenAnOlderCopyBreaksItsTerms() public {
        _track();
        bytes32 id = _issue();
        bytes32 olderCopy = keccak256("a copy a reorg dropped");
        MessageTypesLib.ReceiptMessage memory receipt = _legUnder(id, fromSat, toSat, 95, olderCopy);
        assertEq(mc.pendingInOf(bobId), 90, "reserved at issuance");

        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ReceiptOnOlderTerms(id, polygon, 90);
        vm.prank(token);
        mc.receiveReceipt(polygon, BRIDGE, PEER_KEY, receipt);

        assertTrue(mc.isAwayChainBlocked(polygon), "the away chain is blocked");
        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(mc.ticketOf(id).moved, 95, "applied as it happened");
        assertEq(mc.pendingInOf(bobId), 0, "the reservation is released");
        assertEq(mc.pendingOutOf(aliceId), 0);
        assertEq(TokenReservationStub(token).reservedOf(fromSat), 0);
    }

    /// @notice A chain the validation does not involve could not have executed anything under it: whatever ask
    ///         block hash it names, its leg is rejected, never orphaned, so no peer can end another chain's validation.
    function test_handleSettlement_Success_WhenAnUninvolvedChainNamesAnotherHash() public {
        bytes32 id = _issue();

        vm.prank(token);
        _assertRejected(id, optimism, _legUnder(id, fromSat, toSat, 95, keccak256("not the issued body")));
        vm.prank(token);
        _assertRejected(id, _evmChainKey(block.chainid), _legUnder(id, fromSat, toSat, 50, keccak256("another")));

        _assertUntouched(id);
        assertEq(mc.pendingInOf(bobId), 90, "still reserved");
    }

    /// @notice A receipt inside the terms of an older copy, under the away chain's per-ticket cap, is applied and
    ///         blocks nothing.
    function test_handleSettlement_Success_WhenTheBodyDivergedButTheLegFitsTheTerms() public {
        _track();
        mc.setTicketLimits(polygon, 90, 90);
        bytes32 id = _issue();
        bytes32 olderCopy = keccak256("same terms, another valid until");

        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ReceiptOnOlderTerms(id, polygon, 90);
        vm.prank(token);
        mc.receiveReceipt(polygon, BRIDGE, PEER_KEY, _legUnder(id, fromSat, toSat, 50, olderCopy));

        assertFalse(mc.isAwayChainBlocked(polygon), "nothing blocked");
        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(mc.positionOf(bobId), 50);
    }

    /* ----- Late receipts ----- */

    /// @notice A receipt after the cancel, above what a rule allows now, is applied and announced: nothing stops.
    function test_handleSettlement_Success_WhenALateReconciliationBreachesARule() public {
        _track();
        bytes32 id = _issue();
        _discard(id);
        assertEq(mc.pendingInOf(bobId), 0, "released at discard");
        // Bound after issuance: Bob may receive 40 at most now, and the cancelled ticket lands at 50.
        _bindCappedModule(40);

        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.MoveBreachedRule(id, polygon, 50);
        vm.expectCall(token, abi.encodeCall(IToken.finishMove, (fromSat, toSat, 50, id)), 1);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ReceiptApplied(id, polygon, 50);
        vm.prank(token);
        mc.receiveReceipt(polygon, BRIDGE, PEER_KEY, _leg(id, fromSat, toSat, 50));

        assertFalse(mc.isAwayChainBlocked(polygon), "nothing blocked");
        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(mc.ticketOf(id).moved, 50);
        assertEq(mc.positionOf(bobId), 50, "the receipt is applied anyway");
        assertEq(mc.positionOf(aliceId), BRIDGED_BALANCE - 50);
        assertEq(mc.pendingInOf(bobId), 0, "nothing released twice");
    }

    function test_handleSettlement_Success_WhenADiscardedValidationReconcilesLate() public {
        _track();
        _bindCappedModule(1000);
        bytes32 id = _issue();
        _discard(id);

        vm.recordLogs();
        vm.prank(token);
        mc.receiveReceipt(polygon, BRIDGE, PEER_KEY, _leg(id, fromSat, toSat, 50));

        assertFalse(mc.isAwayChainBlocked(polygon), "nothing blocked");
        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(_countTopic(EventsLib.MoveBreachedRule.selector), 0, "inside the rules");
        assertEq(mc.positionOf(bobId), 50);
        assertEq(mc.pendingInOf(bobId), 0);
        assertEq(mc.pendingOutOf(aliceId), 0);
    }

    function test_handleSettlement_Success_WhenALateReconciliationBetweenOneIdentityNeverBreaches() public {
        _track();
        _bindCappedModule(1);
        _bind(toSat, aliceIdentity);
        bytes32 id = _issue();
        _discard(id);

        vm.prank(token);
        mc.receiveReceipt(polygon, BRIDGE, PEER_KEY, _leg(id, fromSat, toSat, 50));

        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(mc.positionOf(aliceId), BRIDGED_BALANCE, "a relocation moves no position");
    }

    function test_handleSettlement_Success_WhenALateLegIsReplayed() public {
        _track();
        bytes32 id = _issue();
        _discard(id);
        vm.prank(token);
        mc.receiveReceipt(polygon, BRIDGE, PEER_KEY, _leg(id, fromSat, toSat, 50));

        vm.expectCall(token, abi.encodeWithSelector(IToken.finishMove.selector), 0);
        vm.prank(token);
        _assertRejected(id, polygon, _leg(id, fromSat, toSat, 60));

        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Done));
    }

    /* ----- Timely settlement ----- */

    function test_handleSettlement_Success_WhenAPendingValidationSettles() public {
        _track();
        address recorder = _bindAfterTransferModule();
        _bindAllowedAmountModule();
        bytes32 id = _issue();
        assertEq(mc.pendingInOf(bobId), 90, "reserved at the maximum");
        assertEq(mc.pendingOutOf(aliceId), 90);
        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Open), "reserved while pending");

        vm.expectCall(token, abi.encodeCall(IToken.finishMove, (fromSat, toSat, 50, id)), 1);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ReceiptReceived(polygon, id, fromSat, toSat, 50);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ReceiptApplied(id, polygon, 50);
        vm.prank(token);
        mc.receiveReceipt(polygon, BRIDGE, PEER_KEY, _leg(id, fromSat, toSat, 50));

        assertFalse(mc.isAwayChainBlocked(polygon), "nothing blocked");
        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        ITickets.Ticket memory state = mc.ticketOf(id);
        assertEq(state.moved, 50);

        assertEq(mc.pendingInOf(bobId), 0, "the whole reservation is released");
        assertEq(mc.pendingOutOf(aliceId), 0);
        assertEq(mc.positionOf(bobId), 50, "the position moves at the executed amount");
        assertEq(mc.positionOf(aliceId), BRIDGED_BALANCE - 50);
        assertEq(RecordingModule(recorder).transferActionCalls(), 1);
        assertEq(RecordingModule(recorder).lastAmount(), 50);
    }

    function test_handleSettlement_Success_WhenTheContextNamesTheRecordedParties() public {
        _track();
        address recorder = _bindAfterTransferModule();
        bytes32 id = _issue();

        vm.prank(token);
        mc.receiveReceipt(polygon, BRIDGE, PEER_KEY, _leg(id, fromSat, toSat, 50));

        (
            address compliance,
            address fromIdentity,
            address toIdentity,
            bytes32 fromWallet,
            bytes32 toWallet,
            uint256 amountMin,
            uint256 amountMax,
            uint8 kind,
            bool issuance,,
        ) = TrackerOnlyModule(recorder).lastContext();
        assertEq(compliance, address(mc));
        assertEq(fromIdentity, aliceIdentity);
        assertEq(toIdentity, bobIdentity);
        assertEq(fromWallet, WalletKeyLib.canonicalKey(fromSat));
        assertEq(toWallet, WalletKeyLib.canonicalKey(toSat));
        assertEq(amountMin, 50);
        assertEq(amountMax, 50);
        assertEq(kind, MovementKindLib.CROSS_CHAIN, "a settlement is the cross-chain kind a tracker sees");
        assertFalse(issuance);
    }

    /// @notice The trackers are told who executed the validation: the spender it names.
    function test_handleSettlement_Success_WhenTheContextNamesTheValidationSpender() public {
        _track();
        address recorder = _bindAfterTransferModule();
        bytes memory spender = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("spender"));
        vm.prank(aliceIdentity);
        bytes32 id = mc.askToMove(fromSat, toSat, 10, 90, spender, _salt());

        vm.prank(token);
        mc.receiveReceipt(polygon, BRIDGE, PEER_KEY, _leg(id, fromSat, toSat, 50));

        (,,,,,,,,, bytes memory recorded,) = TrackerOnlyModule(recorder).lastContext();
        assertEq(recorded, spender);
        assertEq(mc.ticketOf(id).spender, spender);
    }

    /// @notice A settlement always moves the positions, and always tells the trackers. There is no mode in
    ///         which the compliance applies a movement without recording who now owns the tokens.
    function test_handleSettlement_Success_WhenPositionsMoveAndModulesAreTold() public {
        address recorder = _bindAfterTransferModule();
        _track();
        bytes32 id = _issue();

        vm.prank(token);
        mc.receiveReceipt(polygon, BRIDGE, PEER_KEY, _leg(id, fromSat, toSat, 50));

        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(mc.positionOf(bobId), 50, "the recipient now holds what was executed");
        assertEq(mc.positionOf(aliceId), BRIDGED_BALANCE - 50, "and the sender that much less");
        assertEq(RecordingModule(recorder).transferActionCalls(), 1, "the trackers are told");
    }

    /// @notice A settlement on either end of the issued range is accepted: the bounds are inclusive.
    function test_handleSettlement_Success_WhenTheAmountIsOnABound() public {
        _track();
        bytes32 first = _issue();
        // The first validation reserved its maximum against the sending wallet, so the second can only ask for
        // what is left of it.
        vm.prank(aliceIdentity);
        bytes32 second = mc.askToMove(fromSat, toSat, 5, BRIDGED_BALANCE - 90, "", _salt());
        uint256 secondMax = mc.ticketOf(second).amountMax;

        vm.startPrank(token);
        mc.receiveReceipt(polygon, BRIDGE, PEER_KEY, _leg(first, fromSat, toSat, mc.ticketOf(first).amountMin));
        mc.receiveReceipt(polygon, BRIDGE, PEER_KEY, _leg(second, fromSat, toSat, secondMax));
        vm.stopPrank();

        assertEq(mc.ticketOf(first).moved, 10, "settled at its minimum");
        assertEq(mc.ticketOf(second).moved, secondMax, "settled at its maximum");
    }

    function test_handleSettlement_Success_WhenTheNativeSideIsTheRecipient() public {
        _track();
        address recorder = _bindAfterTransferModule();
        vm.prank(aliceIdentity);
        bytes32 id = mc.askToMove(fromSat, nativeBob, 10, 40, "", _salt());

        vm.expectCall(token, abi.encodeCall(IToken.finishMove, (fromSat, nativeBob, 40, id)), 1);
        vm.prank(token);
        mc.receiveReceipt(polygon, BRIDGE, PEER_KEY, _leg(id, fromSat, nativeBob, 40));

        assertFalse(mc.isAwayChainBlocked(polygon), "nothing blocked");
        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(mc.positionOf(bobId), 40);
        (,,,, bytes32 toWallet,,,,,,) = TrackerOnlyModule(recorder).lastContext();
        assertEq(toWallet, bytes32(uint256(uint160(bob))), "a native wallet is its padded address");
    }

    function test_handleSettlement_Success_WhenTheLegClaimsTheReferenceChain() public {
        vm.prank(aliceIdentity);
        bytes32 id = mc.askToMove(fromSat, nativeBob, 10, 40, "", _salt());

        vm.prank(token);
        _assertRejected(id, _evmChainKey(block.chainid), _leg(id, fromSat, nativeBob, 40));

        _assertUntouched(id);
    }

    function test_handleSettlement_Success_WhenPastTheReleaseDeadlineBeforeAnyDiscard() public {
        _track();
        bytes32 id = _issue();
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Open));

        vm.prank(token);
        mc.receiveReceipt(polygon, BRIDGE, PEER_KEY, _leg(id, fromSat, toSat, 50));

        assertFalse(mc.isAwayChainBlocked(polygon), "nothing blocked");
        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(mc.pendingInOf(bobId), 0, "the reservation was still live and is released");
        assertEq(mc.positionOf(bobId), 50);
    }

    /* ----- An id home does not know ----- */

    /// @notice A receipt for an id with no record is put on hold under its sender, with no destination: the away
    ///         token's balances already moved, and the ask mined again may take it. It blocks nobody.
    function test_receiveReceipt_booksOnHoldWithNoDestination_whenTheTicketIsUnknown() public {
        bytes32 unknown = keccak256("an id this compliance never issued");
        MessageTypesLib.ReceiptMessage memory receipt = _legUnder(unknown, fromSat, toSat, 50, keccak256("body"));

        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ReceiptWithoutTicket(unknown, polygon, fromSat, toSat, 50);
        vm.prank(token);
        mc.receiveReceipt(polygon, BRIDGE, PEER_KEY, receipt);

        ITickets.Ticket memory held = mc.ticketOf(unknown);
        assertEq(uint8(held.status), uint8(ITickets.TicketStatus.OnHold), "on hold");
        assertFalse(held.written, "no ticket home sent answers it");
        assertEq(held.moved, 50, "what the away token moved");
        assertFalse(mc.isAwayChainBlocked(polygon), "nothing blocked");
    }

    /* ----- Helpers ----- */

    /// @dev Cancels `id` the only way a sent ticket is cancelled: an ask for its receipt at its first due time, and
    ///  one waiting time with no answer.
    function _discard(bytes32 id) private {
        uint64 firstAskDueAt = mc.ticketOf(id).validUntil + POLYGON_WINDOW;
        vm.warp(firstAskDueAt);
        mc.sendTicket(id, toSat, "");
        vm.warp(firstAskDueAt + POLYGON_WINDOW + 1);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.prank(stranger);
        mc.cancelTickets(ids);
    }

    function _countTopic(bytes32 topic) private returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) count++;
        }
    }

    function _issue() private returns (bytes32 id) {
        vm.prank(aliceIdentity);
        id = mc.askToMove(fromSat, toSat, 10, 90, "", _salt());
    }

    /// @dev A receipt echoing the copy home sent: what an away token that executed it reports.
    function _leg(bytes32 id, bytes memory from, bytes memory to, uint256 amount)
        private
        view
        returns (MessageTypesLib.ReceiptMessage memory)
    {
        return _legUnder(id, from, to, amount, _issuedAskBlockHash(id));
    }

    /// @dev A receipt echoing the copy named by `askBlockHash`, with the maximum and valid until home recorded: what
    ///  an away token that executed another copy of the same terms reports. Reads storage, so it makes no call and
    ///  consumes no prank.
    function _legUnder(bytes32 id, bytes memory from, bytes memory to, uint256 amount, bytes32 askBlockHash)
        private
        view
        returns (MessageTypesLib.ReceiptMessage memory)
    {
        (uint256 amountMax, uint64 validUntil) = _issuedMaximumAndValidUntil(id);
        return MessageTypesLib.ReceiptMessage({
            ticketId: id,
            from: from,
            to: to,
            amount: amount,
            askBlockHash: askBlockHash,
            seenMax: amountMax,
            seenValidUntil: validUntil,
            half: 0,
            answer: MessageTypesLib.ReceiptAnswer.Executed
        });
    }

    /// @dev A bad receipt: refused, and the chain that sent it to be blocked. Runs under the caller's prank.
    function _assertRejected(bytes32 id, bytes32 chainKey, MessageTypesLib.ReceiptMessage memory leg) private {
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ReceiptRefused(id, chainKey, leg.amount, leg.askBlockHash);
        mc.receiveReceipt(chainKey, BRIDGE, PEER_KEY, leg);
        assertTrue(mc.isAwayChainBlocked(chainKey), "the chain that sent it is blocked");
    }

    /// @dev A duplicate delivery emits its notification and `ReceiptDuplicate`, and nothing a judged leg emits.
    function _assertOnlyADuplicateWasAnnounced(Vm.Log[] memory logs) private pure {
        assertEq(logs.length, 2, "the notification and the duplicate, nothing judged again");
        assertEq(logs[0].topics[0], EventsLib.ReceiptReceived.selector);
        assertEq(logs[1].topics[0], EventsLib.ReceiptDuplicate.selector);
    }

    function _assertUntouched(bytes32 id) private view {
        ITickets.Ticket memory state = mc.ticketOf(id);
        assertEq(uint8(state.status), uint8(ITickets.TicketStatus.Open));
        assertEq(state.moved, 0);
    }

    function _bind(bytes memory wallet, address identity) private {
        vm.mockCall(registry, abi.encodeWithSignature("resolveIdentity(bytes)", wallet), abi.encode(identity));
        vm.mockCall(
            registry, abi.encodeWithSignature("isWalletVerified(bytes)", wallet), abi.encode(identity != address(0))
        );
    }

    /// @dev Gives alice's identity the position her satellite wallet holds, the way a real deployment does:
    ///  through the token's mint hook. The compliance keeps positions from the token's first mint, so there
    ///  is nothing to turn on.
    function _track() private {
        address aliceNative = makeAddr("aliceNative");
        vm.mockCall(registry, abi.encodeWithSignature("identity(address)", aliceNative), abi.encode(aliceIdentity));
        vm.prank(token);
        mc.created(aliceNative, BRIDGED_BALANCE);
    }

    function _bindAfterTransferModule() private returns (address module) {
        module = address(
            new ModuleProxy(address(new TrackerOnlyModule()), abi.encodeCall(RecordingModule.initialize, ()))
        );
        mc.addModule(module);
    }

    function _bindAllowedAmountModule() private returns (address module) {
        module = address(new ModuleProxy(address(new RuleOnlyModule()), abi.encodeCall(RecordingModule.initialize, ())));
        mc.addModule(module);
    }

    function _bindCappedModule(uint256 cap) private returns (address module) {
        module = address(
            new ModuleProxy(address(new CappedRecipientModule()), abi.encodeCall(RecordingModule.initialize, ()))
        );
        mc.addModule(module);
        mc.callModuleFunction(abi.encodeCall(CappedRecipientModule.setCap, (cap)), module);
    }

    function _evmChainKey(uint256 chainId) private pure returns (bytes32) {
        (bytes2 chainType, bytes memory chainReference,) =
            InteroperableAddress.parseV1(InteroperableAddress.formatEvmV1(chainId));
        return MessageTypesLib.chainKey(chainType, chainReference);
    }

}
