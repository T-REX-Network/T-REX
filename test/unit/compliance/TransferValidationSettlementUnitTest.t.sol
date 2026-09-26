// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Vm.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ModularComplianceBaseUnitTest } from "./helpers/ModularComplianceBaseUnitTest.t.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
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

contract TransferValidationSettlementUnitTest is ModularComplianceBaseUnitTest {

    uint256 internal constant POLYGON = 137;
    uint256 internal constant OPTIMISM = 10;
    uint64 internal constant VALIDITY_WINDOW = 1 hours;
    uint64 internal constant POLYGON_WINDOW = 30 minutes;
    uint64 internal constant OPTIMISM_WINDOW = 45 minutes;
    uint256 internal constant ISSUED_AT = 1_700_000_000;
    uint256 internal constant BRIDGED_BALANCE = 100;

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
    bytes internal toOptimism;
    bytes internal nativeBob;
    bytes internal carolSat;

    function setUp() public override {
        super.setUp();
        fromSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("aliceOnPolygon"));
        toSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("bobOnPolygon"));
        toOptimism = InteroperableAddress.formatEvmV1(OPTIMISM, makeAddr("bobOnOptimism"));
        nativeBob = InteroperableAddress.formatEvmV1(block.chainid, bob);
        carolSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("carolOnPolygon"));
        aliceId = aliceIdentity;
        bobId = bobIdentity;

        mc.setDefaultValidityWindow(VALIDITY_WINDOW);
        mc.setReconciliationWindow(polygon, POLYGON_WINDOW);
        mc.setReconciliationWindow(optimism, OPTIMISM_WINDOW);

        vm.mockCall(token, abi.encodeWithSignature("identityRegistry()"), abi.encode(registry));
        // The wallet's room lives on the token now, so the mocked token address gets a stub with real
        // arithmetic for those few selectors; `vm.mockCall` still wins for everything mocked explicitly.
        vm.etch(token, address(new TokenReservationStub()).code);
        TokenReservationStub(token).setBridgedBalance(fromSat, BRIDGED_BALANCE);
        vm.mockCall(token, abi.encodeWithSelector(Token.dispatchComplianceValidation.selector), abi.encode(bytes32(0)));
        vm.mockCall(token, abi.encodeWithSelector(IToken.settleValidation.selector), "");
        vm.mockCall(token, abi.encodeWithSelector(IToken.holdInTransit.selector), "");
        _bind(fromSat, aliceIdentity);
        _bind(nativeBob, bobIdentity);
        _bind(toSat, bobIdentity);
        _bind(toOptimism, bobIdentity);

        vm.warp(ISSUED_AT);
    }

    /* ----- Access ----- */

    function test_handleSettlement_RevertWhen_CallerIsNotTheBoundToken() public {
        uint256 id = _issue();

        vm.prank(stranger);
        vm.expectRevert(ErrorsLib.AddressNotATokenBoundToComplianceContract.selector);
        mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));
    }

    /* ----- Leg matching ----- */

    function test_handleSettlement_RevertWhen_AWalletIsMissingOrForeign() public {
        uint256 id = _issue();

        vm.startPrank(token);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementLegMismatch.selector, id));
        mc.handleSettlement(polygon, _leg(id, fromSat, "", 50));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementLegMismatch.selector, id));
        mc.handleSettlement(polygon, _leg(id, "", toSat, 50));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementLegMismatch.selector, id));
        mc.handleSettlement(polygon, _leg(id, fromSat, carolSat, 50));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementLegMismatch.selector, id));
        mc.handleSettlement(polygon, _leg(id, carolSat, toSat, 50));
        vm.stopPrank();

        _assertUntouched(id);
    }

    function test_handleSettlement_RevertWhen_TheOriginIsNotARecordedChain() public {
        uint256 id = _issue();

        vm.prank(token);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementLegMismatch.selector, id));
        mc.handleSettlement(optimism, _leg(id, fromSat, toSat, 50));

        _assertUntouched(id);
    }

    function test_handleSettlement_RevertWhen_AmountIsOutsideTheBounds() public {
        uint256 id = _issue();

        vm.startPrank(token);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementOutOfBounds.selector, id, 9));
        mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 9));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementOutOfBounds.selector, id, 91));
        mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 91));
        vm.stopPrank();

        _assertUntouched(id);
    }

    /* ----- Late reconciliation ----- */

    function test_handleSettlement_Success_WhenALateReconciliationBreachesARule() public {
        _track();
        uint256 id = _issue();
        _discard(id);
        assertEq(mc.pendingInOf(bobId), 0, "released at discard");
        // Bound after issuance: Bob may receive 40 at most now, and the discarded validation settles at 50.
        _bindCappedModule(40);

        vm.expectCall(token, abi.encodeCall(IToken.settleValidation, (fromSat, toSat, 50, id)), 1);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ValidationSettled(id, polygon, 50);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.LateReconciliation(id, polygon);
        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.ValidationIssuancePaused(polygon);
        vm.prank(token);
        bool halt = mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertFalse(halt);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.LateReconciled));
        assertEq(mc.validationOf(id).executedAmount, 50);
        assertTrue(mc.isIssuancePaused(polygon));
        assertEq(mc.positionOf(bobId), 50, "the settlement is applied anyway");
        assertEq(mc.positionOf(aliceId), BRIDGED_BALANCE - 50);
        assertEq(mc.pendingInOf(bobId), 0, "nothing released twice");
    }

    function test_handleSettlement_Success_WhenADiscardedValidationReconcilesLate() public {
        _track();
        _bindCappedModule(1000);
        uint256 id = _issue();
        _discard(id);

        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.LateReconciliation(id, polygon);
        vm.prank(token);
        bool halt = mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertFalse(halt);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.LateReconciled));
        assertFalse(mc.isIssuancePaused(polygon), "a late delivery is cheap to force; pausing on it would be a DoS");
        assertEq(mc.positionOf(bobId), 50);
        assertEq(mc.pendingInOf(bobId), 0);
        assertEq(mc.pendingOutOf(aliceId), 0);
    }

    function test_handleSettlement_Success_WhenALateReconciliationBetweenOneIdentityNeverBreaches() public {
        _track();
        _bindCappedModule(1);
        _bind(toSat, aliceIdentity);
        uint256 id = _issue();
        _discard(id);

        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.LateReconciled));
        assertFalse(mc.isIssuancePaused(polygon), "a relocation asks no rule");
        assertEq(mc.positionOf(aliceId), BRIDGED_BALANCE, "a relocation moves no position");
    }

    function test_handleSettlement_Success_WhenALateLegIsReplayed() public {
        uint256 id = _issue();
        _discard(id);
        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        vm.expectCall(token, abi.encodeWithSelector(IToken.settleValidation.selector), 0);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ReplayedSettlement(id, polygon);
        vm.prank(token);
        bool halt = mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertTrue(halt);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.LateReconciled));
    }

    function test_handleSettlement_Success_WhenTheChainIsAlreadyPausedOnALateLeg() public {
        uint256 id = _issue();
        _discard(id);
        mc.setIssuancePaused(polygon, true);

        vm.recordLogs();
        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.LateReconciled));
        assertTrue(mc.isIssuancePaused(polygon));
        assertEq(_countTopic(EventsLib.LateReconciliation.selector), 1);
        assertEq(_countTopic(EventsLib.ValidationIssuancePaused.selector), 0, "already paused: no second pause");
    }

    function test_handleSettlement_Success_WhenADiscardedCrossChainValidationReconcilesLegByLeg() public {
        _track();
        address recorder = _bindAfterTransferModule();
        uint256 id = _issueCrossChain();
        _discard(id);

        // The discard already gave the wallet its room back, so the late burn leg's hold releases nothing more.
        vm.expectCall(token, abi.encodeCall(IToken.holdInTransit, (fromSat, 50, id, 0)), 1);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ValidationLegConfirmed(id, polygon, 50);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.LateReconciliation(id, polygon);
        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, "", 50));

        assertEq(
            uint8(mc.statusOf(id)),
            uint8(ITransferValidation.ValidationStatus.DiscardedAwaitingMint),
            "still discarded, now owed its mint leg"
        );
        ITransferValidation.Validation memory state = mc.validationOf(id);
        assertEq(state.executedAmount, 50);
        assertFalse(mc.isIssuancePaused(polygon), "a first leg settles nothing, so it breaches nothing");
        assertFalse(mc.isIssuancePaused(optimism));
        assertEq(RecordingModule(recorder).transferActionCalls(), 0, "nothing moved on the first leg");
        assertEq(mc.positionOf(bobId), 0);

        vm.expectCall(token, abi.encodeCall(IToken.settleValidation, (fromSat, toOptimism, 50, id)), 1);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ValidationSettled(id, optimism, 50);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.LateReconciliation(id, optimism);
        vm.prank(token);
        mc.handleSettlement(optimism, _leg(id, "", toOptimism, 50));

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.LateReconciled));
        assertFalse(mc.isIssuancePaused(optimism), "the pair breached nothing on the way in");
        assertEq(RecordingModule(recorder).transferActionCalls(), 1);
        assertEq(RecordingModule(recorder).lastAmount(), 50);
        assertEq(mc.positionOf(bobId), 50);
    }

    function test_discardExpiredValidations_RevertWhen_ALateFirstLegLanded() public {
        uint256 id = _issueCrossChain();
        _discard(id);
        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, "", 50));

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(keeperAccount);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotDiscardable.selector,
                id,
                uint8(ITransferValidation.ValidationStatus.DiscardedAwaitingMint)
            )
        );
        mc.discardExpiredValidations(ids);
    }

    /* ----- Timely settlement ----- */

    function test_handleSettlement_Success_WhenAPendingValidationSettles() public {
        _track();
        address recorder = _bindAfterTransferModule();
        _bindAllowedAmountModule();
        uint256 id = _issue();
        assertEq(mc.pendingInOf(bobId), 90, "reserved at the maximum");
        assertEq(mc.pendingOutOf(aliceId), 90);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending), "reserved while pending");

        vm.expectCall(token, abi.encodeCall(IToken.settleValidation, (fromSat, toSat, 50, id)), 1);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.SettlementNotified(polygon, id, fromSat, toSat, 50);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ValidationSettled(id, polygon, 50);
        vm.prank(token);
        bool halt = mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertFalse(halt);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        ITransferValidation.Validation memory state = mc.validationOf(id);
        assertEq(state.executedAmount, 50);

        assertEq(mc.pendingInOf(bobId), 0, "the whole reservation is released");
        assertEq(mc.pendingOutOf(aliceId), 0);
        assertEq(mc.positionOf(bobId), 50, "the position moves at the executed amount");
        assertEq(mc.positionOf(aliceId), BRIDGED_BALANCE - 50);
        assertEq(RecordingModule(recorder).transferActionCalls(), 1);
        assertEq(RecordingModule(recorder).lastAmount(), 50);
        assertFalse(mc.isIssuancePaused(polygon));
    }

    function test_handleSettlement_Success_WhenTheContextNamesTheRecordedParties() public {
        _track();
        address recorder = _bindAfterTransferModule();
        uint256 id = _issue();

        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        (
            address compliance,
            address fromIdentity,
            address toIdentity,
            bytes32 fromWallet,
            bytes32 toWallet,
            uint256 amountMin,
            uint256 amountMax,
            bool issuance,
        ) = TrackerOnlyModule(recorder).lastContext();
        assertEq(compliance, address(mc));
        assertEq(fromIdentity, aliceIdentity);
        assertEq(toIdentity, bobIdentity);
        assertEq(fromWallet, WalletKeyLib.canonicalKey(fromSat));
        assertEq(toWallet, WalletKeyLib.canonicalKey(toSat));
        assertEq(amountMin, 50);
        assertEq(amountMax, 50);
        assertFalse(issuance);
    }

    /// @notice A settlement always moves the positions, and always tells the trackers. There is no mode in
    ///         which the compliance applies a movement without recording who now owns the tokens.
    function test_handleSettlement_Success_WhenPositionsMoveAndModulesAreTold() public {
        address recorder = _bindAfterTransferModule();
        _track();
        uint256 id = _issue();

        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(mc.positionOf(bobId), 50, "the recipient now holds what was executed");
        assertEq(mc.positionOf(aliceId), BRIDGED_BALANCE - 50, "and the sender that much less");
        assertEq(RecordingModule(recorder).transferActionCalls(), 1, "the trackers are told");
    }

    /// @notice A settlement on either end of the issued range is accepted: the bounds are inclusive.
    function test_handleSettlement_Success_WhenTheAmountIsOnABound() public {
        uint256 first = _issue();
        // The first validation reserved its maximum against the sending wallet, so the second can only be
        // issued for what is left of it.
        uint256 second = _issue();
        uint256 secondMax = mc.validationOf(second).amountMax;

        vm.startPrank(token);
        mc.handleSettlement(polygon, _leg(first, fromSat, toSat, mc.validationOf(first).amountMin));
        mc.handleSettlement(polygon, _leg(second, fromSat, toSat, secondMax));
        vm.stopPrank();

        assertEq(mc.validationOf(first).executedAmount, 10, "settled at its minimum");
        assertEq(mc.validationOf(second).executedAmount, secondMax, "settled at its maximum");
    }

    function test_handleSettlement_Success_WhenTheNativeSideIsTheRecipient() public {
        _track();
        address recorder = _bindAfterTransferModule();
        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(fromSat, nativeBob, 10, 40, "");

        vm.expectCall(token, abi.encodeCall(IToken.settleValidation, (fromSat, nativeBob, 40, id)), 1);
        vm.prank(token);
        bool halt = mc.handleSettlement(polygon, _leg(id, fromSat, nativeBob, 40));

        assertFalse(halt);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(mc.positionOf(bobId), 40);
        (,,,, bytes32 toWallet,,,,) = TrackerOnlyModule(recorder).lastContext();
        assertEq(toWallet, bytes32(uint256(uint160(bob))), "a native wallet is its padded address");
    }

    function test_handleSettlement_RevertWhen_TheLegClaimsTheReferenceChain() public {
        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(fromSat, nativeBob, 10, 40, "");

        vm.prank(token);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementLegMismatch.selector, id));
        mc.handleSettlement(_evmChainKey(block.chainid), _leg(id, fromSat, nativeBob, 40));
    }

    function test_handleSettlement_Success_WhenPastTheReleaseDeadlineBeforeAnyDiscard() public {
        _track();
        uint256 id = _issue();
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Expired));

        vm.prank(token);
        bool halt = mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertFalse(halt);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertFalse(mc.isIssuancePaused(polygon));
        assertEq(mc.pendingInOf(bobId), 0, "the reservation was still live and is released");
        assertEq(mc.positionOf(bobId), 50);
    }

    function test_handleSettlement_Success_WhenAModuleBoundAfterIssuanceSeesTheSettlement() public {
        _track();
        uint256 id = _issue();
        address recorder = _bindAfterTransferModule();

        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertEq(RecordingModule(recorder).transferActionCalls(), 1);
        (, address fromIdentity, address toIdentity,,,,,,) = TrackerOnlyModule(recorder).lastContext();
        assertEq(fromIdentity, aliceIdentity, "the settlement knows whose it is");
        assertEq(toIdentity, bobIdentity);
        assertEq(mc.positionOf(bobId), 50);
    }

    /* ----- Replays ----- */

    function test_handleSettlement_Success_WhenAConsumedLegIsReplayed() public {
        _track();
        address recorder = _bindAfterTransferModule();
        uint256 id = _issue();
        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        vm.expectCall(token, abi.encodeWithSelector(IToken.settleValidation.selector), 0);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ReplayedSettlement(id, polygon);
        vm.prank(token);
        bool halt = mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertTrue(halt);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(mc.validationOf(id).executedAmount, 50);
        assertEq(RecordingModule(recorder).transferActionCalls(), 1, "nothing applied twice");
        assertEq(mc.positionOf(bobId), 50);
    }

    function test_handleSettlement_Success_WhenTheIdWasNeverIssued() public {
        uint256 id = _issue();

        vm.expectCall(token, abi.encodeWithSelector(IToken.settleValidation.selector), 0);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ReplayedSettlement(id + 1, polygon);
        vm.prank(token);
        bool halt = mc.handleSettlement(polygon, _leg(id + 1, fromSat, toSat, 50));

        assertTrue(halt);
        assertEq(mc.validationOf(id + 1).executedAmount, 0);
        assertEq(
            uint8(mc.validationOf(id + 1).status),
            uint8(ITransferValidation.ValidationStatus.Pending),
            "the unknown id recorded nothing"
        );

        vm.prank(token);
        assertTrue(mc.handleSettlement(polygon, _leg(0, fromSat, toSat, 50)));
    }

    /* ----- Two legs ----- */

    function test_handleSettlement_Success_WhenTheBurnLegLandsFirst() public {
        _track();
        address recorder = _bindAfterTransferModule();
        uint256 id = _issueCrossChain();

        vm.expectCall(token, abi.encodeCall(IToken.holdInTransit, (fromSat, 50, id, 90)), 1);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ValidationLegConfirmed(id, polygon, 50);
        vm.prank(token);
        bool halt = mc.handleSettlement(polygon, _leg(id, fromSat, "", 50));

        assertFalse(halt);
        assertEq(RecordingModule(recorder).transferActionCalls(), 0, "nothing moved on the first leg");
        assertEq(mc.pendingInOf(bobId), 90, "the reservation stays live");
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingMint));
        ITransferValidation.Validation memory state = mc.validationOf(id);
        assertEq(state.executedAmount, 50);
        assertEq(state.legWallet, fromSat);

        vm.expectCall(token, abi.encodeCall(IToken.settleValidation, (fromSat, toOptimism, 50, id)), 1);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ValidationSettled(id, optimism, 50);
        vm.prank(token);
        halt = mc.handleSettlement(optimism, _leg(id, "", toOptimism, 50));

        assertFalse(halt);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(RecordingModule(recorder).transferActionCalls(), 1);
        assertEq(mc.pendingInOf(bobId), 0);
        assertEq(mc.positionOf(bobId), 50);
        assertEq(mc.positionOf(aliceId), BRIDGED_BALANCE - 50);
    }

    function test_handleSettlement_Success_WhenTheMintLegLandsFirst() public {
        uint256 id = _issueCrossChain();

        vm.expectCall(token, abi.encodeWithSelector(IToken.holdInTransit.selector), 0);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ValidationLegConfirmed(id, optimism, 60);
        vm.prank(token);
        mc.handleSettlement(optimism, _leg(id, "", toOptimism, 60));

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingBurn));
        ITransferValidation.Validation memory state = mc.validationOf(id);
        assertEq(state.legWallet, toOptimism);

        vm.expectCall(token, abi.encodeCall(IToken.settleValidation, (fromSat, toOptimism, 60, id)), 1);
        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, "", 60));

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(mc.validationOf(id).executedAmount, 60);
    }

    function test_handleSettlement_Success_WhenAwaitingTheMintLegNeverDerivesExpired() public {
        uint256 id = _issueCrossChain();
        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, "", 50));

        vm.warp(ISSUED_AT + VALIDITY_WINDOW + OPTIMISM_WINDOW + 30 days);

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingMint));
    }

    function test_handleSettlement_Success_WhenAConsumedLegOfTwoIsReplayed() public {
        uint256 id = _issueCrossChain();
        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, "", 50));

        vm.expectCall(token, abi.encodeWithSelector(IToken.settleValidation.selector), 0);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ReplayedSettlement(id, polygon);
        vm.prank(token);
        bool halt = mc.handleSettlement(polygon, _leg(id, fromSat, "", 50));

        assertTrue(halt);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingMint));
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingMint));
    }

    function test_handleSettlement_RevertWhen_TheSecondLegCarriesAnotherAmount() public {
        uint256 id = _issueCrossChain();
        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, "", 50));

        vm.prank(token);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementAmountMismatch.selector, id, 50, 51));
        mc.handleSettlement(optimism, _leg(id, "", toOptimism, 51));

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingMint));
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingMint));
    }

    function test_handleSettlement_RevertWhen_ATwoLegValidationGetsAMismatchedLeg() public {
        uint256 id = _issueCrossChain();

        vm.startPrank(token);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementLegMismatch.selector, id));
        mc.handleSettlement(polygon, _leg(id, fromSat, toOptimism, 50));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementLegMismatch.selector, id));
        mc.handleSettlement(optimism, _leg(id, fromSat, "", 50));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementLegMismatch.selector, id));
        mc.handleSettlement(polygon, _leg(id, "", toOptimism, 50));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementLegMismatch.selector, id));
        mc.handleSettlement(polygon, _leg(id, "", "", 50));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementLegMismatch.selector, id));
        mc.handleSettlement(optimism, _leg(id, "", carolSat, 50));
        vm.stopPrank();

        _assertUntouched(id);
    }

    function _discard(uint256 id) private {
        vm.warp(block.timestamp + VALIDITY_WINDOW + OPTIMISM_WINDOW + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(keeperAccount);
        mc.discardExpiredValidations(ids);
    }

    function _countTopic(bytes32 topic) private returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) count++;
        }
    }

    function _issueCrossChain() private returns (uint256 id) {
        vm.prank(aliceIdentity);
        id = mc.requestTransferValidation(fromSat, toOptimism, 10, 90, "");
    }

    function _issue() private returns (uint256 id) {
        vm.prank(aliceIdentity);
        id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");
    }

    function _leg(uint256 id, bytes memory from, bytes memory to, uint256 amount)
        private
        pure
        returns (MessageTypesLib.SettlementNotification memory)
    {
        return MessageTypesLib.SettlementNotification({ validationId: id, from: from, to: to, amount: amount });
    }

    function _assertUntouched(uint256 id) private view {
        ITransferValidation.Validation memory state = mc.validationOf(id);
        assertEq(uint8(state.status), uint8(ITransferValidation.ValidationStatus.Pending));
        assertEq(state.executedAmount, 0);
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
