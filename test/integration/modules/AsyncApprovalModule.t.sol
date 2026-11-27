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

import { ERC3643ErrorsLib } from "contracts/ERC-3643/ERC3643ErrorsLib.sol";
import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { AsyncApprovalModule, IAsyncApprover } from "contracts/compliance/modular/modules/AsyncApprovalModule.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { MaxBalancePerIdentityModule } from "contracts/compliance/modular/modules/MaxBalancePerIdentityModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { TokenLedgerHarness } from "test/integration/helpers/TokenLedgerHarness.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev An approver that answers later, from a callback of its own, as a rule computed with FHE answers from
///      its decryption callback. It records being asked; `decide` stands for the callback.
contract CallbackApprover is IAsyncApprover {

    address public askedCompliance;
    bytes32 public askedValidationId;

    function approvalAsked(address compliance, bytes32 ticketId) external {
        askedCompliance = compliance;
        askedValidationId = ticketId;
    }

    function decide(AsyncApprovalModule module, uint256 amountMax) external {
        module.approveValidation(askedCompliance, askedValidationId, amountMax);
    }

}

/// @dev Issue #127: a cross-chain request waits for answers that may come later, onchain or offchain. The
///      compliance keeps it `WaitingForApproval` and reserved; the module decides who answers, in which order,
///      and answers the compliance once they all approved. A native transfer cannot wait, so an approver stores
///      an approval of that exact transfer instead.
contract AsyncApprovalModuleTest is InteropSuiteTest {

    uint256 internal constant BALANCE = 2000;

    AsyncApprovalModule internal module;
    address internal backend = makeAddr("institutionBackend");
    address internal riskDesk = makeAddr("riskDesk");
    bytes internal aliceSat;
    bytes internal bobSat;
    ERC7786GatewayMock internal gateway;
    uint256 internal approvalCount;

    function setUp() public override {
        super.setUp();
        _openEvmChain(token, POLYGON, address(_newReceiptBridge(POLYGON)));
        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        gateway = ERC7786GatewayMock(token.receiptRouteFor(polygon));

        module = _newModule();
        address[] memory approvers = new address[](1);
        approvers[0] = backend;
        _bind(module, approvers);

        vm.prank(agent);
        token.unpause();
    }

    // ==== Declaration Tests ====

    function test_moduleTypes_NamesRuleTrackerAndApproval() public view {
        IModule.ModuleType[] memory types = module.moduleTypes();
        assertEq(types.length, 3);
        assertEq(uint8(types[2]), uint8(IModule.ModuleType.APPROVAL));
        assertEq(boundCompliance.getModulesByType(IModule.ModuleType.APPROVAL)[0], address(module));
        assertEq(module.name(), "AsyncApprovalModule");
        assertEq(module.approversOf(address(boundCompliance))[0], backend);
    }

    /// @notice A request waits for one answer, so a second module deciding it is refused at binding.
    function test_addModule_RevertWhen_AnApprovalModuleIsAlreadyBound() public {
        AsyncApprovalModule second = _newModule();

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.OneApprovalModuleOnly.selector);
        boundCompliance.addModule(address(second));
    }

    function test_setApprovers_RevertWhen_CalledDirectly() public {
        address[] memory approvers = new address[](1);
        approvers[0] = backend;
        vm.expectRevert(ErrorsLib.OnlyBoundComplianceCanCall.selector);
        module.setApprovers(approvers);
    }

    /// @notice Bound without approvers, a request is refused rather than left to hold its reservation.
    function test_requestTransferValidation_RevertWhen_NoApproverIsSet() public {
        vm.startPrank(deployer);
        boundCompliance.setAsksPaused(true);
        boundCompliance.removeModule(address(module));
        boundCompliance.addModule(address(module));
        boundCompliance.setAsksPaused(false);
        vm.stopPrank();

        vm.prank(address(aliceIdentity));
        vm.expectRevert(ErrorsLib.ApproversNotSet.selector);
        boundCompliance.askToMove(aliceSat, bobSat, 10, 150, "", _salt());
    }

    // ==== The waiting state ====

    /// @notice A request is narrowed and reserved as always, but recorded as waiting: nothing is signed or sent.
    function test_requestTransferValidation_Success_WhenItWaitsForApproval() public {
        uint256 freeBefore = token.availableOf(aliceSat);
        bytes32 salt = _salt();
        bytes32 id = _ticketId(aliceSat, bobSat, "", 10, 150, salt);

        vm.expectEmit(address(boundCompliance));
        emit EventsLib.TicketWaitingForApproval(
            id, aliceSat, bobSat, "", 10, 150, uint64(block.timestamp + VALIDITY_WINDOW)
        );
        vm.prank(address(aliceIdentity));
        boundCompliance.askToMove(aliceSat, bobSat, 10, 150, "", salt);

        ITickets.Ticket memory waiting = boundCompliance.ticketOf(id);
        assertEq(uint8(waiting.status), uint8(ITickets.TicketStatus.WaitingForApproval));
        assertEq(waiting.askBlockHash, bytes32(0), "nothing issued yet");
        assertEq(gateway.queueLength(), 0, "nothing sent");
        assertEq(token.availableOf(aliceSat), freeBefore - 150, "the room is held while it waits");
        assertEq(_ledger().pendingInOf(address(bobIdentity)), 150, "and counted against the recipient");
        assertEq(module.requestOf(address(boundCompliance), id).amountMax, 150);
    }

    /// @notice One entry point: an agent's request waits as the identity's does.
    function test_requestTransferValidation_Success_WhenAnAgentRequestsItWaitsToo() public {
        bytes32 id = _requestValidation(agent, aliceSat, bobSat, 10, 150);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.WaitingForApproval));
    }

    /// @notice The last approval only records the request as fully approved; `finalize`, from anyone, issues it
    ///         and sends the legs. The satellite's deadline stays the request's: the wait comes out of it.
    function test_finalize_Success_WhenTheApproverApproved() public {
        uint256 requestedAt = block.timestamp;
        bytes32 id = _request(10, 150);
        vm.warp(block.timestamp + 10 minutes);

        vm.expectEmit(address(module));
        emit AsyncApprovalModule.ValidationFullyApproved(address(boundCompliance), id, 150);
        _approve(backend, id, 150);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.WaitingForApproval));
        assertTrue(module.requestOf(address(boundCompliance), id).fullyApproved);

        vm.prank(makeAddr("anyone"));
        module.finalize(address(boundCompliance), id);
        assertEq(gateway.queueLength(), 0, "the answer sends nothing");
        vm.prank(makeAddr("anyone"));
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        ITickets.Ticket memory issued = boundCompliance.ticketOf(id);
        assertEq(uint8(issued.status), uint8(ITickets.TicketStatus.Open));
        assertTrue(issued.askBlockHash != bytes32(0), "issued");
        assertEq(issued.validUntil, requestedAt + VALIDITY_WINDOW, "the rules are never older than one window");
        assertEq(gateway.queueLength(), 1, "the leg is sent");
        assertEq(_decodeQueuedValidation(gateway, 0).amountMax, 150);
        assertEq(module.requestOf(address(boundCompliance), id).amountMax, 0, "forgotten once issued");
    }

    /// @notice A request waiting for approval reserves its maximum on the wallet, so a bring home asked meanwhile
    ///         is bounded by what is left: no bring home ever burns the tokens the approved ticket moves.
    function test_bringHome_reverts_when_aTicketWaitingForApprovalReservedTheTokens() public {
        bytes32 id = _request(10, 1500);
        assertEq(token.availableOf(aliceSat), 500, "1500 reserved against 2000");

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RequestAboveBalance.selector, aliceSat, 500, 800));
        boundCompliance.bringHome(aliceSat, 800, alice, _salt());

        _approve(backend, id, 1500);
        _finalize(id);
        assertEq(boundCompliance.ticketOf(id).amountMax, 1500, "the earlier reservation stands");

        gateway.relay(_liteSettles(gateway, token, _settlement(id, aliceSat, bobSat, 1500)));

        assertEq(token.awayBalanceOf(aliceSat), 500);
        assertEq(token.awayBalanceOf(bobSat), 1500);
        assertFalse(token.paused());
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
    }

    /// @notice An approver can lower the maximum; the difference goes back at once.
    function test_approveValidation_Success_WhenTheApproverNarrows() public {
        bytes32 id = _request(10, 150);
        uint256 freeWhileWaiting = token.availableOf(aliceSat);

        _approve(backend, id, 60);
        _finalize(id);

        assertEq(boundCompliance.ticketOf(id).amountMax, 60);
        assertEq(_decodeQueuedValidation(gateway, 0).amountMax, 60, "the satellite executes at most that");
        assertEq(token.availableOf(aliceSat), freeWhileWaiting + 90, "the difference is released");
        assertEq(_ledger().pendingInOf(address(bobIdentity)), 60);
    }

    /// @notice An approver can only narrow: a larger answer keeps the requested maximum.
    function test_approveValidation_Success_WhenTheAnswerIsAboveTheRequest() public {
        bytes32 id = _request(10, 150);

        _approve(backend, id, 1000);
        _finalize(id);

        assertEq(boundCompliance.ticketOf(id).amountMax, 150, "never widened");
    }

    /// @notice A refusal releases everything and sends nothing.
    function test_refuseValidation_Success_WhenTheApproverRefuses() public {
        uint256 freeBefore = token.availableOf(aliceSat);
        bytes32 id = _request(10, 150);

        vm.expectEmit(address(boundCompliance));
        emit EventsLib.ValidationApprovalRefused(id);
        vm.prank(backend);
        module.refuseValidation(address(boundCompliance), id);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Cancelled));
        assertEq(token.availableOf(aliceSat), freeBefore, "the room comes back");
        assertEq(_ledger().pendingInOf(address(bobIdentity)), 0);
        assertEq(gateway.queueLength(), 0, "nothing sent");
    }

    /// @notice A maximum below the requested minimum is a refusal.
    function test_approveValidation_Success_WhenTheAnswerIsBelowTheMinimumItRefuses() public {
        bytes32 id = _request(50, 150);

        _approve(backend, id, 40);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Cancelled));
    }

    function test_approveValidation_RevertWhen_TheCallerIsNotTheApprover() public {
        bytes32 id = _request(10, 150);

        vm.prank(riskDesk);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotTheNextApprover.selector, riskDesk, backend));
        module.approveValidation(address(boundCompliance), id, 150);
    }

    /// @notice Once every approver approved, nobody is left to answer and the caller is told to finalize; once
    ///         issued, the request is forgotten.
    function test_approveValidation_RevertWhen_TheRequestWasAlreadyAnswered() public {
        bytes32 id = _request(10, 150);
        _approve(backend, id, 150);

        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AlreadyFullyApproved.selector, id));
        module.approveValidation(address(boundCompliance), id, 150);
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AlreadyFullyApproved.selector, id));
        module.refuseValidation(address(boundCompliance), id);

        _finalize(id);
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownApprovalRequest.selector, id));
        module.approveValidation(address(boundCompliance), id, 150);
    }

    function test_finalize_RevertWhen_NotEveryApproverApproved() public {
        _setApprovers(backend, riskDesk);
        bytes32 id = _request(10, 150);
        _approve(backend, id, 150);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotFullyApproved.selector, id));
        module.finalize(address(boundCompliance), id);
    }

    /// @notice The answer sends nothing, so a chain blocked while the request waited does not hold it: the ticket is
    ///         opened, and its first send waits for the block to be lifted.
    function test_finalize_opensTheTicket_andTheFirstSendWaitsForABlockedChain() public {
        bytes32 id = _request(10, 150);
        _approve(backend, id, 150);
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);

        module.finalize(address(boundCompliance), id);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open), "opened");
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, polygon));
        boundCompliance.sendTicket(id, polygon, bobSat, "");

        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);
        boundCompliance.sendTicket(id, polygon, bobSat, "");
        assertEq(gateway.queueLength(), 1, "sent once the block is lifted");
    }

    /// @notice The answer sends nothing, so a paused token does not hold it: the ticket is opened, and its first send
    ///         waits for the unpause.
    function test_finalize_opensTheTicket_andTheFirstSendWaitsForTheUnpause() public {
        bytes32 id = _request(10, 150);
        _approve(backend, id, 150);
        vm.prank(agent);
        token.pause();

        module.finalize(address(boundCompliance), id);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open), "opened");
        vm.expectRevert(ErrorsLib.TokenPaused.selector);
        boundCompliance.sendTicket(id, polygon, bobSat, "");
        assertEq(gateway.queueLength(), 0, "nothing sent");

        vm.prank(agent);
        token.unpause();
        boundCompliance.sendTicket(id, polygon, bobSat, "");
        assertEq(gateway.queueLength(), 1);
    }

    /// @notice A refusal sends nothing, so it goes through while the token is paused and gives the room back.
    function test_refuseValidation_Success_WhileTheTokenIsPaused() public {
        uint256 freeBefore = token.availableOf(aliceSat);
        bytes32 id = _request(10, 150);
        vm.prank(agent);
        token.pause();

        vm.prank(backend);
        module.refuseValidation(address(boundCompliance), id);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Cancelled));
        assertEq(token.availableOf(aliceSat), freeBefore);
    }

    // ==== Several approvers ====

    /// @notice Approvers answer in order, and the lowest maximum wins.
    function test_approveValidation_Success_WhenTwoApproversAnswerInOrder() public {
        _setApprovers(backend, riskDesk);
        bytes32 id = _request(10, 150);

        vm.prank(riskDesk);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotTheNextApprover.selector, riskDesk, backend));
        module.approveValidation(address(boundCompliance), id, 150);

        _approve(backend, id, 80);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.WaitingForApproval));

        _approve(riskDesk, id, 120);
        _finalize(id);
        assertEq(boundCompliance.ticketOf(id).amountMax, 80, "the lowest maximum approved");
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
    }

    /// @notice The first refusal refuses: a later approver is never asked.
    function test_refuseValidation_Success_WhenTheSecondApproverRefuses() public {
        _setApprovers(backend, riskDesk);
        bytes32 id = _request(10, 150);
        _approve(backend, id, 150);

        vm.prank(riskDesk);
        module.refuseValidation(address(boundCompliance), id);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Cancelled));
    }

    // ==== An approver that answers from a callback ====

    /// @notice An approver contract is told in the request's own transaction and answers later, from its own
    ///         callback, with no offchain party in between.
    function test_approveValidation_Success_WhenAContractApproverAnswersFromItsCallback() public {
        CallbackApprover approver = new CallbackApprover();
        _setApprovers(address(approver), address(0));
        bytes32 id = _request(10, 150);
        assertEq(approver.askedValidationId(), id, "told in the request's transaction");
        assertEq(approver.askedCompliance(), address(boundCompliance));

        vm.warp(block.timestamp + 10 minutes);
        approver.decide(module, 100);
        assertTrue(module.requestOf(address(boundCompliance), id).fullyApproved, "the callback only approves");

        _finalize(id);
        assertEq(boundCompliance.ticketOf(id).amountMax, 100);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
    }

    /// @notice Telling an approver is best effort: a contract that does not listen never refuses the request.
    function test_requestTransferValidation_Success_WhenTheApproverContractDoesNotListen() public {
        _setApprovers(address(token), address(0));

        bytes32 id = _request(10, 150);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.WaitingForApproval));
    }

    // ==== Deadline ====

    /// @notice Past the deadline anyone cancels an unanswered request, and its
    ///         reservation comes back.
    function test_cancelTickets_Success_WhenAnUnansweredRequestPassedItsDeadline() public {
        uint256 freeBefore = token.availableOf(aliceSat);
        bytes32 id = _request(10, 150);
        vm.warp(block.timestamp + VALIDITY_WINDOW);

        vm.prank(makeAddr("anyone"));
        boundCompliance.cancelTickets(_ids(id));

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Cancelled));
        assertEq(token.availableOf(aliceSat), freeBefore, "released");
        assertEq(_ledger().pendingInOf(address(bobIdentity)), 0);
    }

    /// @notice A request nobody answered by its deadline still reads `WaitingForApproval`: the clock moves no
    ///         ticket, and the cancel is what ends it.
    function test_statusOf_Success_WhenAnUnansweredRequestPassedItsDeadline() public {
        bytes32 id = _request(10, 150);
        vm.warp(block.timestamp + VALIDITY_WINDOW - 1);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.WaitingForApproval));

        vm.warp(block.timestamp + 1);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.WaitingForApproval));
    }

    function test_cancelTickets_RevertWhen_TheRequestIsBeforeItsDeadline() public {
        bytes32 id = _request(10, 150);
        uint64 deadline = uint64(block.timestamp + VALIDITY_WINDOW);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.CancelNotDue.selector, id, deadline));
        boundCompliance.cancelTickets(_ids(id));
    }

    /// @notice Only the approval module answers, an approver calling the compliance directly included.
    function test_answerApproval_RevertWhen_TheCallerIsNotTheApprovalModule() public {
        bytes32 id = _request(10, 150);

        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotTheApprovalModule.selector, backend));
        boundCompliance.answerApproval(id, 150);
    }

    function test_finalize_RevertWhen_TheDeadlinePassed() public {
        bytes32 id = _request(10, 150);
        uint64 deadline = uint64(block.timestamp + VALIDITY_WINDOW);
        _approve(backend, id, 150);
        vm.warp(deadline);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationExpired.selector, id, deadline));
        module.finalize(address(boundCompliance), id);
    }

    function test_answerApproval_RevertWhen_TheValidationIsNotWaiting() public {
        bytes32 id = _request(10, 150);
        _approve(backend, id, 150);
        _finalize(id);

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotAwaitingApproval.selector, id, uint8(ITickets.TicketStatus.Open)
            )
        );
        boundCompliance.answerApproval(id, 150);
    }

    /// @notice While waiting nothing was sent, so there is no leg to resend and nothing for the keeper.
    function test_resendValidation_RevertWhen_TheValidationIsWaiting() public {
        bytes32 id = _request(10, 150);

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotResendable.selector, id, uint8(ITickets.TicketStatus.WaitingForApproval)
            )
        );
        vm.prank(address(aliceIdentity));
        boundCompliance.sendTicket(id, polygon, bobSat, "");
    }

    // ==== With the other rules ====

    /// @notice Every rule ran at the request: an onchain cap narrows before the approver is even asked.
    function test_requestTransferValidation_Success_WhenAnotherRuleNarrowsBeforeTheApprovers() public {
        _bindCap(60);

        bytes32 id = _request(10, 150);

        assertEq(module.requestOf(address(boundCompliance), id).amountMax, 60, "the approver sees the cap");
        _approve(backend, id, 150);
        _finalize(id);
        assertEq(boundCompliance.ticketOf(id).amountMax, 60);
    }

    /// @notice Waiting requests hold room, so two of them cannot jointly break a cap.
    function test_requestTransferValidation_Success_WhenTwoWaitingRequestsShareACap() public {
        _bindCap(200);

        bytes32 first = _request(10, 150);
        bytes32 second = _request(10, 150);

        assertEq(module.requestOf(address(boundCompliance), first).amountMax, 150);
        assertEq(module.requestOf(address(boundCompliance), second).amountMax, 50, "sees the first one waiting");
    }

    /// @notice A validation approved later settles on what the satellite reports, as any other.
    function test_handleSettlement_Success_WhenAnApprovedValidationSettles() public {
        bytes32 id = _request(0, 100);
        _approve(backend, id, 100);
        _finalize(id);

        gateway.relay(_liteSettles(gateway, token, _settlement(id, aliceSat, bobSat, 80)));

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(_ledger().positionOf(address(bobIdentity)), 80);
    }

    /// @notice Nothing was sent for a request still waiting, so a receipt for it answers no ticket home sent: its
    ///         amount is put on hold under the sender with no destination, no chain is blocked, and the request can
    ///         no longer be answered.
    function test_receiveReceipt_putsTheReceiptOnHold_whenTheTicketStillWaitsForApproval() public {
        bytes32 id = _request(10, 150);

        MessageTypesLib.ReceiptMessage memory receipt = _settlementUnder(id, aliceSat, bobSat, 100, keccak256("body"));
        uint256 index = _liteSettles(gateway, token, receipt);
        vm.expectEmit(address(boundCompliance));
        emit EventsLib.ReceiptWithoutTicket(id, polygon, aliceSat, bobSat, 100);
        gateway.relay(index);

        assertFalse(token.paused(), "the token keeps running");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "nothing blocks the chain by itself");
        ITickets.Ticket memory held = boundCompliance.ticketOf(id);
        assertEq(uint8(held.status), uint8(ITickets.TicketStatus.OnHold));
        assertFalse(held.written, "no ticket home sent answers it");
        assertEq(_ledger().positionOf(address(bobIdentity)), 0, "nothing applied to the receiver");
    }

    /// @notice A refusal is final: a receipt for the refused move, which was never sent, is put on hold with no
    ///         destination rather than applied as that move.
    function test_receiveReceipt_putsTheReceiptOnHold_whenTheTicketWasRefused() public {
        bytes32 id = _request(10, 150);
        vm.prank(backend);
        module.refuseValidation(address(boundCompliance), id);

        gateway.relay(_liteSettles(gateway, token, _settlementUnder(id, aliceSat, bobSat, 100, keccak256("body"))));

        assertFalse(token.paused());
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.OnHold), "on hold, no destination");
        assertEq(token.onHoldOf(id), 100);
        assertEq(_ledger().positionOf(address(bobIdentity)), 0, "nothing applied to the receiver");
    }

    /// @notice A relocation between one identity's own wallets changes no position: the module approves it inside
    ///         the request, which opens it; anyone then makes its first send.
    function test_requestTransferValidation_Success_WhenARelocationIsApprovedAtOnce() public {
        bytes memory aliceOther = _linkSatelliteWallet(aliceIdentity, POLYGON, makeAccount("aliceOtherOnPolygon"));

        vm.prank(address(aliceIdentity));
        bytes32 id = boundCompliance.askToMove(aliceSat, aliceOther, 10, 150, "", _salt());

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
        assertEq(gateway.queueLength(), 0, "opened, not sent");
        boundCompliance.sendTicket(id, polygon, aliceOther, "");
        assertEq(gateway.queueLength(), 1, "sent by anyone");
        assertEq(module.requestOf(address(boundCompliance), id).amountMax, 0, "nobody was asked");
    }

    /// @notice The approver list does not change while a request waits: what was approved so far was approved under
    ///         the list in place, and a module setting changes only while nothing is reserved.
    function test_setApprovers_reverts_when_aRequestIsWaiting() public {
        _setApprovers(backend, riskDesk);
        bytes32 id = _request(10, 150);
        _approve(backend, id, 150);

        address[] memory approvers = new address[](1);
        approvers[0] = riskDesk;
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.TicketsStillReserved.selector);
        boundCompliance.callModuleFunction(
            abi.encodeCall(AsyncApprovalModule.setApprovers, (approvers)), address(module)
        );

        vm.warp(block.timestamp + VALIDITY_WINDOW);
        boundCompliance.cancelTickets(_ids(id));
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Cancelled));
    }

    /// @notice The module is not removed while a request waits for it: the rules a ticket was asked under stay
    ///         bound until it ends. Once the request is cancelled past its deadline, with asks paused, it goes.
    function test_removeModule_reverts_when_aRequestIsWaiting() public {
        bytes32 waiting = _request(10, 150);
        vm.startPrank(deployer);
        boundCompliance.setAsksPaused(true);
        vm.expectRevert(ErrorsLib.TicketsStillReserved.selector);
        boundCompliance.removeModule(address(module));
        vm.stopPrank();

        assertEq(uint8(boundCompliance.statusOf(waiting)), uint8(ITickets.TicketStatus.WaitingForApproval));
        vm.warp(block.timestamp + VALIDITY_WINDOW);
        boundCompliance.cancelTickets(_ids(waiting));
        assertEq(uint8(boundCompliance.statusOf(waiting)), uint8(ITickets.TicketStatus.Cancelled));

        vm.prank(deployer);
        boundCompliance.removeModule(address(module));
        assertFalse(boundCompliance.isModuleBound(address(module)));
    }

    /// @notice Unbound, requests are issued at once again: the module is the whole switch.
    function test_requestTransferValidation_Success_WhenTheModuleIsRemoved() public {
        vm.startPrank(deployer);
        boundCompliance.setAsksPaused(true);
        boundCompliance.removeModule(address(module));
        boundCompliance.setAsksPaused(false);
        vm.stopPrank();

        bytes32 id = _request(10, 150);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
        assertEq(gateway.queueLength(), 1);
    }

    // ==== Native transfer Tests ====

    function test_transfer_Success_WhenApprovedOnce() public {
        _mintTo(charlie, 200);
        _approveNative(charlie, bob, 100, uint64(block.timestamp + 1 days));

        vm.prank(charlie);
        token.transfer(bob, 100);
        assertEq(module.approvalOf(address(boundCompliance), charlie, bob, 100).count, 0, "used up");

        vm.prank(charlie);
        vm.expectRevert(ERC3643ErrorsLib.ComplianceNotFollowed.selector);
        token.transfer(bob, 100);
    }

    function test_transfer_Success_WhenApprovedTwice() public {
        _mintTo(charlie, 200);
        uint64 expiry = uint64(block.timestamp + 1 days);
        _approveNative(charlie, bob, 100, expiry);
        _approveNative(charlie, bob, 100, expiry);

        vm.startPrank(charlie);
        token.transfer(bob, 100);
        token.transfer(bob, 100);
        vm.stopPrank();

        assertEq(token.balanceOf(bob), 200);
    }

    function test_transfer_RevertWhen_TheAmountDiffers() public {
        _mintTo(charlie, 200);
        _approveNative(charlie, bob, 100, uint64(block.timestamp + 1 days));

        vm.prank(charlie);
        vm.expectRevert(ERC3643ErrorsLib.ComplianceNotFollowed.selector);
        token.transfer(bob, 99);
    }

    function test_transfer_RevertWhen_TheApprovalExpired() public {
        _mintTo(charlie, 200);
        uint64 expiry = uint64(block.timestamp + 1 days);
        _approveNative(charlie, bob, 100, expiry);
        vm.warp(expiry);

        vm.prank(charlie);
        vm.expectRevert(ERC3643ErrorsLib.ComplianceNotFollowed.selector);
        token.transfer(bob, 100);

        vm.prank(backend);
        module.revokeApproval(address(boundCompliance), charlie, bob, 100);
        assertEq(module.approvalOf(address(boundCompliance), charlie, bob, 100).count, 0);
    }

    function test_revokeApproval_RevertWhen_TheComplianceIsNotBound() public {
        vm.prank(backend);
        vm.expectRevert(ErrorsLib.ComplianceNotBound.selector);
        module.revokeApproval(makeAddr("otherCompliance"), charlie, bob, 100);
    }

    function test_revokeApproval_RevertWhen_NothingIsApproved() public {
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TransferNotApproved.selector, charlie, bob, 100));
        module.revokeApproval(address(boundCompliance), charlie, bob, 100);
    }

    function test_approveTransfer_RevertWhen_TheExpiryHasPassed() public {
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ExpiryInPast.selector, uint64(block.timestamp)));
        module.approveTransfer(address(boundCompliance), _nextApprovalId(), charlie, bob, 100, uint64(block.timestamp));
    }

    /// @notice Only the compliance's own approvers approve its native transfers, so on a module shared by
    ///         several issuers, one issuer's approver cannot act for another.
    function test_approveTransfer_RevertWhen_TheCallerIsNotAnApprover() public {
        vm.prank(riskDesk);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAnApprover.selector, riskDesk));
        module.approveTransfer(
            address(boundCompliance), _nextApprovalId(), charlie, bob, 100, uint64(block.timestamp + 1 days)
        );
    }

    /// @notice A decision delivered twice approves one transfer, not two, even after a rebind.
    function test_approveTransfer_RevertWhen_TheApprovalIdWasUsed() public {
        bytes32 approvalId = keccak256("decision");
        uint64 expiry = uint64(block.timestamp + 1 days);
        vm.prank(backend);
        module.approveTransfer(address(boundCompliance), approvalId, charlie, bob, 100, expiry);

        address[] memory approvers = new address[](1);
        approvers[0] = backend;
        vm.startPrank(deployer);
        boundCompliance.setAsksPaused(true);
        boundCompliance.removeModule(address(module));
        vm.stopPrank();
        _bind(module, approvers);

        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ApprovalIdAlreadyUsed.selector, approvalId));
        module.approveTransfer(address(boundCompliance), approvalId, charlie, bob, 100, expiry);
        assertTrue(module.isApprovalIdUsed(address(boundCompliance), backend, approvalId));
    }

    /// @notice Each approver has its own ids: one approver's id never blocks another's decision.
    function test_approveTransfer_Success_WhenTwoApproversUseTheSameApprovalId() public {
        _setApprovers(backend, riskDesk);
        bytes32 approvalId = keccak256("decision");
        uint64 expiry = uint64(block.timestamp + 1 days);

        vm.prank(backend);
        module.approveTransfer(address(boundCompliance), approvalId, charlie, bob, 100, expiry);
        vm.prank(riskDesk);
        module.approveTransfer(address(boundCompliance), approvalId, charlie, bob, 100, expiry);

        assertEq(module.approvalOf(address(boundCompliance), charlie, bob, 100).count, 2);
        assertTrue(module.isApprovalIdUsed(address(boundCompliance), riskDesk, approvalId));
    }

    function test_mint_Success_WithoutAnApproval() public {
        _mintTo(bob, 100);

        assertEq(token.balanceOf(bob), 100);
    }

    function test_forcedTransfer_Success_WithoutAnApproval() public {
        _mintTo(charlie, 100);
        _approveNative(charlie, bob, 100, uint64(block.timestamp + 1 days));

        vm.prank(agent);
        token.forcedTransfer(charlie, bob, 100);

        assertEq(module.approvalOf(address(boundCompliance), charlie, bob, 100).count, 1, "left for a transfer");
    }

    // ==== Helpers ====

    // ==== Leaving the compliance Tests ====

    /// @notice A request waiting for approval is reserved like an issued validation, so it keeps the token on its
    ///         compliance: once the token left, giving the reservation back would call a token no longer bound.
    function test_setCompliance_RevertWhen_ARequestIsWaitingForApproval() public {
        _request(10, 150);
        _recallAndBurnTheWholeSupply();
        ModularCompliance fresh = _newUnboundComplianceProxy(address(trexImplementationAuthority));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.TicketsStillReserved.selector);
        token.setCompliance(address(fresh));

        assertEq(boundCompliance.getTokenBound(), address(token), "the token stays bound");
    }

    /// @notice A refusal, a narrowing and an unanswered request each give back what they reserved in the
    ///         ledger's total as well, so once they are over nothing is promised and the token may leave.
    function test_setCompliance_Success_WhenEveryWaitingRequestIsOver() public {
        bytes32 refused = _request(10, 150);
        vm.prank(backend);
        module.refuseValidation(address(boundCompliance), refused);

        bytes32 unanswered = _request(10, 150);
        bytes32 narrowed = _request(10, 150);
        _approve(backend, narrowed, 60);
        _finalize(narrowed);
        assertEq(boundCompliance.ticketOf(narrowed).amountMax, 60, "issued at the approved maximum");

        // The sent one is cancelled once an ask for its receipt went unanswered; the unanswered request by anyone.
        _cancelUnanswered(narrowed, bobSat, "");
        vm.prank(makeAddr("anyone"));
        boundCompliance.cancelTickets(_ids(unanswered));
        assertEq(token.reservedOf(aliceSat), 0, "every reservation came back");

        _recallAndBurnTheWholeSupply();
        // The token leaves its compliance only once home stopped waiting for every ticket it wrote.
        vm.warp(boundCompliance.ticketOf(narrowed).stopWaitingAt);
        ModularCompliance fresh = _newUnboundComplianceProxy(address(trexImplementationAuthority));
        vm.prank(deployer);
        token.setCompliance(address(fresh));

        assertEq(address(token.compliance()), address(fresh));
    }

    /// @dev Brings alice's satellite tokens home and burns them, since the token leaves its compliance only at zero
    ///  supply. The ledger's own transition stands in for a bring home that burned the whole position: what these
    ///  tests are about is the binding, and a bring home is bounded by what the waiting requests reserve.
    function _recallAndBurnTheWholeSupply() private {
        vm.startPrank(agent);
        TokenLedgerHarness(address(token)).ledgerBringHome(aliceSat, alice, BALANCE);
        token.burn(alice, BALANCE);
        vm.stopPrank();
        assertEq(token.totalSupply(), 0, "no supply left");
    }

    function _newModule() private returns (AsyncApprovalModule) {
        return AsyncApprovalModule(
            address(
                new ModuleProxy(
                    address(new AsyncApprovalModule()),
                    abi.encodeCall(AsyncApprovalModule.initialize, (address(suiteManager)))
                )
            )
        );
    }

    function _bind(AsyncApprovalModule approvalModule, address[] memory approvers) private {
        bytes[] memory settings = new bytes[](1);
        settings[0] = abi.encodeCall(AsyncApprovalModule.setApprovers, (approvers));
        // An approval module is bound only while asks are paused, so no ask is taken under the rules of neither.
        vm.startPrank(deployer);
        boundCompliance.setAsksPaused(true);
        boundCompliance.addAndSetModule(address(approvalModule), settings);
        boundCompliance.setAsksPaused(false);
        vm.stopPrank();
    }

    /// @dev Sets one or two approvers; a zero second one means one.
    function _setApprovers(address first, address second) private {
        address[] memory approvers = new address[](second == address(0) ? 1 : 2);
        approvers[0] = first;
        if (second != address(0)) approvers[1] = second;
        vm.prank(deployer);
        boundCompliance.callModuleFunction(
            abi.encodeCall(AsyncApprovalModule.setApprovers, (approvers)), address(module)
        );
    }

    function _request(uint256 min, uint256 max) private returns (bytes32) {
        return _requestValidation(address(aliceIdentity), aliceSat, bobSat, min, max);
    }

    function _approve(address approver, bytes32 ticketId, uint256 amountMax) private {
        vm.prank(approver);
        module.approveValidation(address(boundCompliance), ticketId, amountMax);
    }

    /// @dev The module's answer opens the ticket and sends nothing: anyone makes the first send.
    function _finalize(bytes32 ticketId) private {
        module.finalize(address(boundCompliance), ticketId);
        boundCompliance.sendTicket(ticketId, polygon, bobSat, "");
    }

    function _ids(bytes32 ticketId) private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = ticketId;
    }

    function _approveNative(address from, address to, uint256 amount, uint64 expiry) private {
        vm.prank(backend);
        module.approveTransfer(address(boundCompliance), _nextApprovalId(), from, to, amount, expiry);
    }

    function _nextApprovalId() private returns (bytes32) {
        return bytes32(++approvalCount);
    }

    function _mintTo(address holder, uint256 amount) private {
        vm.prank(agent);
        token.mint(holder, amount);
    }

    function _bindCap(uint256 cap) private {
        MaxBalancePerIdentityModule capRule = MaxBalancePerIdentityModule(
            address(
                new ModuleProxy(
                    address(new MaxBalancePerIdentityModule()),
                    abi.encodeCall(MaxBalancePerIdentityModule.initialize, (address(suiteManager)))
                )
            )
        );
        bytes[] memory settings = new bytes[](1);
        settings[0] = abi.encodeCall(MaxBalancePerIdentityModule.setMaxBalance, (cap));
        vm.prank(deployer);
        boundCompliance.addAndSetModule(address(capRule), settings);
    }

    function _ledger() private view returns (IComplianceLedger) {
        return IComplianceLedger(address(boundCompliance));
    }

}
