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

import { ModularComplianceBaseUnitTest } from "./helpers/ModularComplianceBaseUnitTest.t.sol";
import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ITREXMessaging } from "contracts/interop/ITREXMessaging.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "contracts/libraries/WalletKeyLib.sol";
import { IToken } from "contracts/token/IToken.sol";
import { Token } from "contracts/token/Token.sol";
import { RecordingModule, TrackerOnlyModule } from "test/integration/mocks/CapabilityModules.sol";
import { TokenReservationStub } from "test/unit/compliance/helpers/TokenReservationStub.sol";

contract TicketsDiscardUnitTest is ModularComplianceBaseUnitTest {

    uint256 internal constant POLYGON = 137;
    uint256 internal constant OPTIMISM = 10;
    uint64 internal constant VALIDITY_WINDOW = 1 hours;
    uint64 internal constant POLYGON_WINDOW = 30 minutes;
    uint64 internal constant OPTIMISM_WINDOW = 45 minutes;
    uint256 internal constant ISSUED_AT = 1_700_000_000;
    uint256 internal constant BRIDGED_BALANCE = 100;

    bytes32 internal polygon = _evmChainKey(POLYGON);
    bytes32 internal optimism = _evmChainKey(OPTIMISM);
    address internal aliceIdentity = makeAddr("AliceIdentity");
    address internal bobIdentity = makeAddr("BobIdentity");
    address internal aliceId;
    address internal bobId;
    bytes internal fromSat;
    bytes internal toSat;

    function setUp() public override {
        super.setUp();
        fromSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("aliceOnPolygon"));
        toSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("bobOnPolygon"));
        aliceId = aliceIdentity;
        bobId = bobIdentity;

        mc.setDefaultValidityWindow(VALIDITY_WINDOW);
        mc.setWaitingTime(polygon, POLYGON_WINDOW);
        mc.setWaitingTime(optimism, OPTIMISM_WINDOW);

        vm.mockCall(token, abi.encodeWithSignature("identityRegistry()"), abi.encode(registry));
        // The wallet's room lives on the token now, so the mocked token address gets a stub with real
        // arithmetic for those few selectors; `vm.mockCall` still wins for everything mocked explicitly.
        vm.etch(token, address(new TokenReservationStub()).code);
        TokenReservationStub(token).setBridgedBalance(fromSat, BRIDGED_BALANCE);
        vm.mockCall(token, abi.encodeWithSelector(Token.sendOnTicketRoute.selector), abi.encode(bytes32(0)));
        // Both away chains have their receipt route open on the token, so a ticket toward them may be cancelled.
        vm.mockCall(token, abi.encodeCall(ITREXMessaging.isChainOpen, (polygon)), abi.encode(true));
        vm.mockCall(token, abi.encodeCall(ITREXMessaging.isChainOpen, (optimism)), abi.encode(true));
        _bind(fromSat, aliceIdentity);
        _bind(toSat, bobIdentity);

        vm.warp(ISSUED_AT);
    }

    /* ----- Status ----- */

    function test_statusOf_Success_WhenFreshlyIssued() public {
        bytes32 id = _issue();

        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Open));
        ITickets.Ticket memory state = mc.ticketOf(id);
        assertEq(uint8(state.status), uint8(ITickets.TicketStatus.Open));
        assertEq(state.moved, 0);
    }

    function test_statusOf_Success_WhenPastExpiryButNotPastReleaseAt() public {
        bytes32 id = _issue();

        vm.warp(ISSUED_AT + VALIDITY_WINDOW + 1);
        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Open));

        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW);
        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Open));
    }

    /// @notice The clock moves no ticket: past its waiting time it is still `Open`, and a cancel ends it.
    function test_statusOf_Success_WhenPastReleaseAtItStaysOpen() public {
        bytes32 id = _issue();

        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);

        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Open));
    }

    function test_statusOf_RevertWhen_IdWasNeverIssued() public {
        bytes32 id = _issue();

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownTicket.selector, 0));
        mc.statusOf(bytes32(uint256(0)));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownTicket.selector, bytes32(uint256(id) + 1)));
        mc.statusOf(bytes32(uint256(id) + 1));
    }

    function test_stateOf_Success_WhenIdWasNeverIssued() public view {
        ITickets.Ticket memory state = mc.ticketOf(bytes32(uint256(42)));

        assertEq(uint8(state.status), 0);
        assertEq(state.moved, 0);
    }

    /* ----- Discard ----- */

    function test_discardExpiredValidations_Success_WhenExpired() public {
        _track();
        address recorder = _bindAfterTransferModule();
        bytes32 id = _issue();
        assertEq(mc.pendingInOf(bobId), 90);
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);

        vm.expectCall(token, abi.encodeCall(IToken.releaseFromTicket, (fromSat, 90)), 1);
        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.TicketCancelled(id);
        vm.prank(keeperAccount);
        mc.cancelTickets(_ids(id));

        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Cancelled));
        assertEq(mc.pendingInOf(bobId), 0, "the reservation is released");
        assertEq(mc.pendingOutOf(aliceId), 0);
        assertEq(mc.positionOf(aliceId), BRIDGED_BALANCE, "nothing moved");
        assertEq(mc.positionOf(bobId), 0);
        assertEq(RecordingModule(recorder).transferActionCalls(), 0, "a discard involves no module");
    }

    function test_discardExpiredValidations_Success_WhenTheReleaseFreesTheRoomForTheNext() public {
        _track();
        bytes32 id = _issue();
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);

        vm.prank(keeperAccount);
        mc.cancelTickets(_ids(id));

        vm.expectCall(token, abi.encodeCall(IToken.reserveForTicket, (fromSat, 90)), 1);
        vm.prank(aliceIdentity);
        bytes32 next = mc.askToMove(fromSat, toSat, 10, 90, "", _salt());
        assertEq(mc.ticketOf(next).amountMax, 90, "issued as if the discarded one never happened");
    }

    /// @notice A relocation between one identity's wallets reserves nothing against the identity, so its
    ///         discard has nothing to give back there. The wallet's share is still released.
    function test_discardExpiredValidations_Success_WhenNothingWasReservedAgainstTheIdentities() public {
        _track();
        _bind(toSat, aliceIdentity);
        bytes32 id = _issue();
        assertTrue(mc.ticketOf(id).relocation, "nothing was reserved against the identities");
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);

        vm.expectCall(token, abi.encodeCall(IToken.releaseFromTicket, (fromSat, 90)), 1);
        vm.prank(keeperAccount);
        mc.cancelTickets(_ids(id));

        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Cancelled));
        assertEq(mc.pendingInOf(bobId), 0);
    }

    function test_discardExpiredValidations_Success_WhenBatchingSeveralIds() public {
        _track();
        bytes32 first = _issue();
        bytes32 second = _issue();
        assertEq(mc.pendingInOf(bobId), 100, "both reserved, the second capped by the wallet");
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = first;
        ids[1] = second;
        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.TicketCancelled(first);
        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.TicketCancelled(second);
        vm.prank(keeperAccount);
        mc.cancelTickets(ids);

        assertEq(uint8(mc.statusOf(first)), uint8(ITickets.TicketStatus.Cancelled));
        assertEq(uint8(mc.statusOf(second)), uint8(ITickets.TicketStatus.Cancelled));
        assertEq(mc.pendingInOf(bobId), 0);
        assertEq(mc.pendingOutOf(aliceId), 0);
    }

    function test_discardExpiredValidations_RevertWhen_NonKeeperBeforeTheSecondWindow() public {
        bytes32 id = _issue();
        uint64 publicAt = uint64(ISSUED_AT + VALIDITY_WINDOW + 2 * POLYGON_WINDOW);
        vm.warp(publicAt);

        vm.prank(agentAccount);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationNotPubliclyDiscardable.selector, id, publicAt));
        mc.cancelTickets(_ids(id));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationNotPubliclyDiscardable.selector, id, publicAt));
        mc.cancelTickets(_ids(id));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationNotPubliclyDiscardable.selector, id, publicAt));
        mc.cancelTickets(_ids(id));

        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Open));
    }

    function test_discardExpiredValidations_Success_WhenAnyoneAfterTheSecondWindow() public {
        bytes32 id = _issue();
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + 2 * POLYGON_WINDOW + 1);

        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.TicketCancelled(id);
        vm.prank(stranger);
        mc.cancelTickets(_ids(id));

        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Cancelled));
        assertEq(mc.pendingInOf(bobId), 0);
        assertEq(mc.pendingOutOf(aliceId), 0);
    }

    function test_discardExpiredValidations_RevertWhen_IdWasNeverIssued() public {
        vm.prank(keeperAccount);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownTicket.selector, 7));
        mc.cancelTickets(_ids(bytes32(uint256(7))));
    }

    function test_discardExpiredValidations_RevertWhen_NotYetReleasable() public {
        bytes32 id = _issue();
        uint64 waitingEndsAt = uint64(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW);

        vm.warp(waitingEndsAt);
        vm.prank(keeperAccount);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.CancelNotDue.selector, id, waitingEndsAt));
        mc.cancelTickets(_ids(id));

        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Open));
    }

    function test_discardExpiredValidations_RevertWhen_AlreadyDiscarded() public {
        bytes32 id = _issue();
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        vm.prank(keeperAccount);
        mc.cancelTickets(_ids(id));

        vm.prank(keeperAccount);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.TicketNotCancellable.selector, id, uint8(ITickets.TicketStatus.Cancelled))
        );
        mc.cancelTickets(_ids(id));
    }

    /// @notice A ticket its receipt ended is done: no clock makes it cancellable, and its reservation is released
    ///         once, by the receipt.
    function test_discardExpiredValidations_RevertWhen_TheReceiptEndedTheTicket() public {
        _track();
        bytes32 id = _issueAndReceive();
        vm.warp(ISSUED_AT + 10 * VALIDITY_WINDOW);

        vm.prank(keeperAccount);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.TicketNotCancellable.selector, id, uint8(ITickets.TicketStatus.Done))
        );
        mc.cancelTickets(_ids(id));

        assertEq(mc.pendingInOf(bobId), 0, "released once, by the receipt");
    }

    function test_discardExpiredValidations_RevertWhen_OneIdOfTheBatchIsRefused() public {
        _track();
        bytes32 expired = _issue();
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        bytes32 pending = _issue();
        uint64 pendingReleaseAt = uint64(block.timestamp + VALIDITY_WINDOW + POLYGON_WINDOW);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = expired;
        ids[1] = pending;
        vm.prank(keeperAccount);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.CancelNotDue.selector, pending, pendingReleaseAt));
        mc.cancelTickets(ids);

        assertEq(uint8(mc.statusOf(expired)), uint8(ITickets.TicketStatus.Open));
        assertEq(mc.pendingInOf(bobId), 100, "the whole batch is rolled back");
    }

    function _issue() private returns (bytes32 id) {
        vm.prank(aliceIdentity);
        id = mc.askToMove(fromSat, toSat, 10, 90, "", _salt());
    }

    function _issueAndReceive() private returns (bytes32 id) {
        id = _issue();
        // Read before the prank: the lookup is an external call too and would consume it.
        ITickets.Ticket memory issued = mc.ticketOf(id);
        MessageTypesLib.ReceiptMessage memory receipt = MessageTypesLib.ReceiptMessage({
            ticketId: id,
            from: fromSat,
            to: toSat,
            amount: 50,
            askBlockHash: issued.askBlockHash,
            seenMax: issued.amountMax,
            seenValidUntil: issued.validUntil,
            half: 0,
            answer: MessageTypesLib.ReceiptAnswer.Executed
        });
        // The token's side of the move is not what these tests are about.
        vm.mockCall(token, abi.encodeCall(IToken.finishMove, (fromSat, toSat, 50, id)), "");
        vm.prank(token);
        mc.receiveReceipt(polygon, makeAddr("bridge"), keccak256("peer"), receipt);
    }

    function _ids(bytes32 id) private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = id;
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

    function _evmChainKey(uint256 chainId) private pure returns (bytes32) {
        (bytes2 chainType, bytes memory chainReference,) =
            InteroperableAddress.parseV1(InteroperableAddress.formatEvmV1(chainId));
        return MessageTypesLib.chainKey(chainType, chainReference);
    }

}
