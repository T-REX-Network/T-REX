// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ERC3643ErrorsLib } from "contracts/ERC-3643/ERC3643ErrorsLib.sol";
import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { AsyncApprovalModule, IAsyncApprover } from "contracts/compliance/modular/modules/AsyncApprovalModule.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { MaxBalancePerIdentityModule } from "contracts/compliance/modular/modules/MaxBalancePerIdentityModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev An approver that answers later, from a callback of its own, as a rule computed with FHE answers from
///      its decryption callback. It records being asked; `decide` stands for the callback.
contract CallbackApprover is IAsyncApprover {

    address public askedCompliance;
    bytes32 public askedValidationId;

    function approvalAsked(address compliance, bytes32 validationId) external {
        askedCompliance = compliance;
        askedValidationId = validationId;
    }

    function decide(AsyncApprovalModule module, uint256 amountMax) external {
        module.approveValidation(askedCompliance, askedValidationId, amountMax);
    }

}

/// @dev Issue #127: a cross-chain request waits for answers that may come later, onchain or offchain. The
///      compliance keeps it `AwaitingApproval` and reserved; the module decides who answers, in which order,
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
        _openEvmChain(token, POLYGON, address(_newTrustedGateway(POLYGON)));
        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        gateway = ERC7786GatewayMock(token.routeFor(polygon));

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
        boundCompliance.removeModule(address(module));
        boundCompliance.addModule(address(module));
        vm.stopPrank();

        vm.prank(address(aliceIdentity));
        vm.expectRevert(ErrorsLib.ApproversNotSet.selector);
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 150, "", _salt());
    }

    // ==== The waiting state ====

    /// @notice A request is narrowed and reserved as always, but recorded as waiting: nothing is signed or sent.
    function test_requestTransferValidation_Success_WhenItWaitsForApproval() public {
        uint256 freeBefore = token.availableOf(aliceSat);
        bytes32 salt = _salt();
        bytes32 id = _validationId(aliceSat, salt);

        vm.expectEmit(address(boundCompliance));
        emit EventsLib.TransferValidationAwaitingApproval(
            id, aliceSat, bobSat, "", 10, 150, uint64(block.timestamp + VALIDITY_WINDOW)
        );
        vm.prank(address(aliceIdentity));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 150, "", salt);

        ITransferValidation.Validation memory waiting = boundCompliance.validationOf(id);
        assertEq(uint8(waiting.status), uint8(ITransferValidation.ValidationStatus.AwaitingApproval));
        assertEq(waiting.hash, bytes32(0), "nothing issued yet");
        assertEq(gateway.queueLength(), 0, "nothing sent");
        assertEq(token.availableOf(aliceSat), freeBefore - 150, "the room is held while it waits");
        assertEq(_ledger().pendingInOf(address(bobIdentity)), 150, "and counted against the recipient");
        assertEq(module.requestOf(address(boundCompliance), id).amountMax, 150);
    }

    /// @notice One entry point: an agent's request waits as the identity's does.
    function test_requestTransferValidation_Success_WhenAnAgentRequestsItWaitsToo() public {
        bytes32 id = _requestValidation(agent, aliceSat, bobSat, 10, 150);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingApproval));
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
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingApproval));
        assertTrue(module.requestOf(address(boundCompliance), id).fullyApproved);

        vm.prank(makeAddr("anyone"));
        module.finalize(address(boundCompliance), id);

        ITransferValidation.Validation memory issued = boundCompliance.validationOf(id);
        assertEq(uint8(issued.status), uint8(ITransferValidation.ValidationStatus.Pending));
        assertTrue(issued.hash != bytes32(0), "issued");
        assertEq(issued.expiry, requestedAt + VALIDITY_WINDOW, "the rules are never older than one window");
        assertEq(gateway.queueLength(), 1, "the leg is sent");
        assertEq(_decodeQueuedValidation(gateway, 0).amountMax, 150);
        assertEq(module.requestOf(address(boundCompliance), id).amountMax, 0, "forgotten once issued");
    }

    /// @notice An approver can lower the maximum; the difference goes back at once.
    function test_approveValidation_Success_WhenTheApproverNarrows() public {
        bytes32 id = _request(10, 150);
        uint256 freeWhileWaiting = token.availableOf(aliceSat);

        _approve(backend, id, 60);
        _finalize(id);

        assertEq(boundCompliance.validationOf(id).amountMax, 60);
        assertEq(_decodeQueuedValidation(gateway, 0).amountMax, 60, "the satellite executes at most that");
        assertEq(token.availableOf(aliceSat), freeWhileWaiting + 90, "the difference is released");
        assertEq(_ledger().pendingInOf(address(bobIdentity)), 60);
    }

    /// @notice An approver can only narrow: a larger answer keeps the requested maximum.
    function test_approveValidation_Success_WhenTheAnswerIsAboveTheRequest() public {
        bytes32 id = _request(10, 150);

        _approve(backend, id, 1000);
        _finalize(id);

        assertEq(boundCompliance.validationOf(id).amountMax, 150, "never widened");
    }

    /// @notice A refusal releases everything and sends nothing.
    function test_refuseValidation_Success_WhenTheApproverRefuses() public {
        uint256 freeBefore = token.availableOf(aliceSat);
        bytes32 id = _request(10, 150);

        vm.expectEmit(address(boundCompliance));
        emit EventsLib.ValidationApprovalRefused(id);
        vm.prank(backend);
        module.refuseValidation(address(boundCompliance), id);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Discarded));
        assertEq(token.availableOf(aliceSat), freeBefore, "the room comes back");
        assertEq(_ledger().pendingInOf(address(bobIdentity)), 0);
        assertEq(gateway.queueLength(), 0, "nothing sent");
    }

    /// @notice A maximum below the requested minimum is a refusal.
    function test_approveValidation_Success_WhenTheAnswerIsBelowTheMinimumItRefuses() public {
        bytes32 id = _request(50, 150);

        _approve(backend, id, 40);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Discarded));
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

    /// @notice A chain paused while the request waited makes `finalize` revert, never an approver. The request
    ///         stays fully approved, and `finalize` goes through once the chain is open again.
    function test_finalize_Success_WhenRetriedAfterAPausedChainReopens() public {
        bytes32 id = _request(10, 150);
        _approve(backend, id, 150);
        vm.prank(deployer);
        boundCompliance.setIssuancePaused(polygon, true);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationIssuancePaused.selector, polygon));
        module.finalize(address(boundCompliance), id);
        assertTrue(module.requestOf(address(boundCompliance), id).fullyApproved, "still there to retry");

        vm.prank(deployer);
        boundCompliance.setIssuancePaused(polygon, false);
        module.finalize(address(boundCompliance), id);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
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
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingApproval));

        _approve(riskDesk, id, 120);
        _finalize(id);
        assertEq(boundCompliance.validationOf(id).amountMax, 80, "the lowest maximum approved");
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
    }

    /// @notice The first refusal refuses: a later approver is never asked.
    function test_refuseValidation_Success_WhenTheSecondApproverRefuses() public {
        _setApprovers(backend, riskDesk);
        bytes32 id = _request(10, 150);
        _approve(backend, id, 150);

        vm.prank(riskDesk);
        module.refuseValidation(address(boundCompliance), id);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Discarded));
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
        assertEq(boundCompliance.validationOf(id).amountMax, 100);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
    }

    /// @notice Telling an approver is best effort: a contract that does not listen never refuses the request.
    function test_requestTransferValidation_Success_WhenTheApproverContractDoesNotListen() public {
        _setApprovers(address(token), address(0));

        bytes32 id = _request(10, 150);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingApproval));
    }

    // ==== Deadline ====

    /// @notice Past the deadline anyone discards an unanswered request, through the keeper's own call, and its
    ///         reservation comes back.
    function test_discardExpiredValidations_Success_WhenAnUnansweredRequestPassedItsDeadline() public {
        uint256 freeBefore = token.availableOf(aliceSat);
        bytes32 id = _request(10, 150);
        vm.warp(block.timestamp + VALIDITY_WINDOW);

        vm.prank(makeAddr("anyone"));
        boundCompliance.discardExpiredValidations(_ids(id));

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Discarded));
        assertEq(token.availableOf(aliceSat), freeBefore, "released");
        assertEq(_ledger().pendingInOf(address(bobIdentity)), 0);
    }

    /// @notice A request nobody answered by its deadline reads `Expired`, as a `Pending` validation past its
    ///         release does: either can now be discarded.
    function test_statusOf_Success_WhenAnUnansweredRequestPassedItsDeadline() public {
        bytes32 id = _request(10, 150);
        vm.warp(block.timestamp + VALIDITY_WINDOW - 1);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingApproval));

        vm.warp(block.timestamp + 1);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Expired));
        assertEq(
            uint8(boundCompliance.validationOf(id).status),
            uint8(ITransferValidation.ValidationStatus.AwaitingApproval),
            "derived, never stored"
        );
    }

    function test_discardExpiredValidations_RevertWhen_TheRequestIsBeforeItsDeadline() public {
        bytes32 id = _request(10, 150);
        uint64 deadline = uint64(block.timestamp + VALIDITY_WINDOW);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationNotReleasable.selector, id, deadline));
        boundCompliance.discardExpiredValidations(_ids(id));
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
                ErrorsLib.ValidationNotAwaitingApproval.selector,
                id,
                uint8(ITransferValidation.ValidationStatus.Pending)
            )
        );
        boundCompliance.answerApproval(id, 150);
    }

    /// @notice While waiting nothing was sent, so there is no leg to resend and nothing for the keeper.
    function test_resendValidation_RevertWhen_TheValidationIsWaiting() public {
        bytes32 id = _request(10, 150);

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotResendable.selector,
                id,
                uint8(ITransferValidation.ValidationStatus.AwaitingApproval)
            )
        );
        vm.prank(address(aliceIdentity));
        boundCompliance.resendValidation(id, polygon, bobSat, "");
    }

    // ==== With the other rules ====

    /// @notice Every rule ran at the request: an onchain cap narrows before the approver is even asked.
    function test_requestTransferValidation_Success_WhenAnotherRuleNarrowsBeforeTheApprovers() public {
        _bindCap(60);

        bytes32 id = _request(10, 150);

        assertEq(module.requestOf(address(boundCompliance), id).amountMax, 60, "the approver sees the cap");
        _approve(backend, id, 150);
        _finalize(id);
        assertEq(boundCompliance.validationOf(id).amountMax, 60);
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

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(_ledger().positionOf(address(bobIdentity)), 80);
    }

    /// @notice Nothing was sent for a request still waiting, so a leg for it is one the satellite executed
    ///         under a body this chain never issued: parked under the id, the chain paused, the request
    ///         untouched. Issued, `settleParkedLeg` settles it; see `ReorgRecovery.t.sol`.
    function test_handleSettlement_ParksTheLeg_WhenTheValidationIsStillWaiting() public {
        bytes32 id = _request(10, 150);

        uint256 index = _liteSettles(gateway, token, _settlementUnder(id, aliceSat, bobSat, 100, keccak256("body")));
        vm.expectEmit(address(boundCompliance));
        emit EventsLib.SettlementParked(id, polygon, 100, keccak256("body"));
        gateway.relay(index);

        assertFalse(token.paused(), "the token keeps running");
        assertTrue(token.isInboundPaused(polygon), "the chain that executed what was never sent is paused");
        assertTrue(boundCompliance.parkedLegOf(id, polygon).exists);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingApproval));
        assertEq(_ledger().positionOf(address(bobIdentity)), 0, "nothing applied");
    }

    /// @notice A refusal is final: a leg for the refused movement is parked for the operator rather than
    ///         reconciled late, since it was never sent, and stays parked once refused.
    function test_handleSettlement_ParksTheLeg_WhenTheValidationWasRefused() public {
        bytes32 id = _request(10, 150);
        vm.prank(backend);
        module.refuseValidation(address(boundCompliance), id);

        gateway.relay(_liteSettles(gateway, token, _settlementUnder(id, aliceSat, bobSat, 100, keccak256("body"))));

        assertFalse(token.paused());
        assertTrue(token.isInboundPaused(polygon));
        assertTrue(boundCompliance.parkedLegOf(id, polygon).exists, "left for the operator");
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Discarded));
        assertEq(_ledger().positionOf(address(bobIdentity)), 0, "nothing applied");
    }

    /// @notice A relocation between one identity's own wallets changes no position: the module approves it inside
    ///         the request, and the leg goes out at once.
    function test_requestTransferValidation_Success_WhenARelocationIsApprovedAtOnce() public {
        bytes memory aliceOther = _linkSatelliteWallet(aliceIdentity, POLYGON, makeAccount("aliceOtherOnPolygon"));

        vm.prank(address(aliceIdentity));
        bytes32 id = boundCompliance.requestTransferValidation(aliceSat, aliceOther, 10, 150, "", _salt());

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
        assertEq(gateway.queueLength(), 1, "sent in the request's own transaction");
        assertEq(module.requestOf(address(boundCompliance), id).amountMax, 0, "nobody was asked");
    }

    /// @notice A new approver list stops the requests already waiting: what was approved so far was approved
    ///         under the old list. They are discarded at their deadline.
    function test_approveValidation_RevertWhen_TheApproversChanged() public {
        _setApprovers(backend, riskDesk);
        bytes32 id = _request(10, 150);
        _approve(backend, id, 150);

        _setApprovers(riskDesk, address(0));

        vm.prank(riskDesk);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ApproversChanged.selector, id));
        module.approveValidation(address(boundCompliance), id, 150);

        vm.warp(block.timestamp + VALIDITY_WINDOW);
        boundCompliance.discardExpiredValidations(_ids(id));
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Discarded));
    }

    /// @notice Unbinding the module turns new requests back into immediate issuances, but a request already
    ///         waiting keeps waiting until its deadline, then is discarded.
    function test_removeModule_Success_WhenARequestIsAlreadyWaiting() public {
        bytes32 waiting = _request(10, 150);
        vm.prank(deployer);
        boundCompliance.removeModule(address(module));

        assertEq(uint8(boundCompliance.statusOf(waiting)), uint8(ITransferValidation.ValidationStatus.AwaitingApproval));
        vm.warp(block.timestamp + VALIDITY_WINDOW);
        boundCompliance.discardExpiredValidations(_ids(waiting));
        assertEq(uint8(boundCompliance.statusOf(waiting)), uint8(ITransferValidation.ValidationStatus.Discarded));
    }

    /// @notice Unbound, requests are issued at once again: the module is the whole switch.
    function test_requestTransferValidation_Success_WhenTheModuleIsRemoved() public {
        vm.prank(deployer);
        boundCompliance.removeModule(address(module));

        bytes32 id = _request(10, 150);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
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
        vm.prank(deployer);
        boundCompliance.removeModule(address(module));
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
        vm.prank(deployer);
        boundCompliance.addAndSetModule(address(approvalModule), settings);
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

    function _approve(address approver, bytes32 validationId, uint256 amountMax) private {
        vm.prank(approver);
        module.approveValidation(address(boundCompliance), validationId, amountMax);
    }

    function _finalize(bytes32 validationId) private {
        module.finalize(address(boundCompliance), validationId);
    }

    function _ids(bytes32 validationId) private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = validationId;
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
