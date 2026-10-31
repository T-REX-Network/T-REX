// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Vm.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ModularComplianceBaseUnitTest } from "./helpers/ModularComplianceBaseUnitTest.t.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { MovementKindLib } from "contracts/compliance/modular/MovementKindLib.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ISettlementHandler } from "contracts/interop/ISettlementHandler.sol";
import { ITREXMessaging } from "contracts/interop/ITREXMessaging.sol";
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
        vm.mockCall(token, abi.encodeWithSelector(ITREXMessaging.isInboundPaused.selector), abi.encode(false));
        vm.mockCall(token, abi.encodeWithSelector(IToken.settleValidation.selector), "");
        vm.mockCall(token, abi.encodeWithSelector(IToken.holdInTransit.selector), "");
        vm.mockCall(token, abi.encodeWithSelector(IToken.applyVerdict.selector), "");
        _bind(fromSat, aliceIdentity);
        _bind(nativeBob, bobIdentity);
        _bind(toSat, bobIdentity);
        _bind(toOptimism, bobIdentity);

        vm.warp(ISSUED_AT);
    }

    /* ----- Access ----- */

    function test_handleSettlement_RevertWhen_CallerIsNotTheBoundToken() public {
        bytes32 id = _issue();

        vm.prank(stranger);
        vm.expectRevert(ErrorsLib.AddressNotATokenBoundToComplianceContract.selector);
        mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));
    }

    /* ----- Leg matching: a leg outside the issued terms is consumed with a verdict, never left deliverable ----- */

    /// @notice Wrong or missing wallets under the issued hash: the Lite broke rule 6 on the body it was sent.
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

    /// @notice An amount outside the range under the issued hash: the Lite broke rule 5. Same outcome.
    function test_handleSettlement_Success_WhenAmountIsOutsideTheBounds() public {
        bytes32 id = _issue();

        vm.startPrank(token);
        _assertRejected(id, polygon, _leg(id, fromSat, toSat, 9));
        _assertRejected(id, polygon, _leg(id, fromSat, toSat, 91));
        vm.stopPrank();

        _assertUntouched(id);
    }

    /// @notice An amount outside the range under another hash: the Lite executed a body this chain never
    ///         canonically issued, which a reorg orphaned. No leg had landed, so the validation ends there and
    ///         what it reserved comes back; the chain is paused.
    function test_handleSettlement_Success_WhenAnOrphanedBodyWasExecutedBeforeAnyLeg() public {
        bytes32 id = _issue();
        bytes32 orphaned = keccak256("the wider body a reorg dropped");
        assertEq(mc.pendingInOf(bobId), 90, "reserved at issuance");

        vm.expectCall(token, abi.encodeWithSelector(IToken.settleValidation.selector), 0);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ValidationOrphaned(id, polygon, 95, orphaned);
        vm.prank(token);
        ISettlementHandler.Verdict verdict = mc.handleSettlement(polygon, _legUnder(id, fromSat, toSat, 95, orphaned));

        assertEq(uint8(verdict), uint8(ISettlementHandler.Verdict.PauseChain));
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Orphaned));
        assertEq(mc.validationOf(id).executedAmount, 0, "nothing applied");
        assertEq(mc.pendingInOf(bobId), 0, "the reservation is released");
        assertEq(mc.pendingOutOf(aliceId), 0);
        assertEq(TokenReservationStub(token).reservedOf(fromSat), 0);

        // Terminal: a leg inside the terms arriving now is a replay.
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ReplayedSettlement(id, polygon);
        vm.prank(token);
        assertEq(
            uint8(mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50))),
            uint8(ISettlementHandler.Verdict.PauseChain)
        );
    }

    /// @notice The same orphaned leg once a leg had already landed: nothing can be released, the pair stands
    ///         for the keeper to resolve, and the chain is paused.
    function test_handleSettlement_Success_WhenAnOrphanedBodyWasExecutedAfterALegLanded() public {
        bytes32 id = _issueCrossChain();
        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, "", 50));
        bytes32 orphaned = keccak256("another body");

        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ValidationOrphaned(id, optimism, 95, orphaned);
        vm.prank(token);
        ISettlementHandler.Verdict verdict = mc.handleSettlement(optimism, _legUnder(id, "", toOptimism, 95, orphaned));

        assertEq(uint8(verdict), uint8(ISettlementHandler.Verdict.PauseChain));
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingMint));
        assertEq(mc.validationOf(id).executedAmount, 50);
    }

    /// @notice A leg inside the terms under another hash settles: the hash is evidence, the terms are the gate.
    function test_handleSettlement_Success_WhenTheBodyDivergedButTheLegFitsTheTerms() public {
        _track();
        bytes32 id = _issue();
        bytes32 diverged = keccak256("same terms, another expiry");

        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.SettlementBodyDiverged(id, polygon, diverged);
        vm.prank(token);
        ISettlementHandler.Verdict verdict = mc.handleSettlement(polygon, _legUnder(id, fromSat, toSat, 50, diverged));

        assertEq(uint8(verdict), uint8(ISettlementHandler.Verdict.None));
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(mc.positionOf(bobId), 50);
    }

    /* ----- Late reconciliation ----- */

    function test_handleSettlement_Success_WhenALateReconciliationBreachesARule() public {
        _track();
        bytes32 id = _issue();
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
        ISettlementHandler.Verdict verdict = mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertEq(uint8(verdict), uint8(ISettlementHandler.Verdict.None));
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
        bytes32 id = _issue();
        _discard(id);

        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.LateReconciliation(id, polygon);
        vm.prank(token);
        ISettlementHandler.Verdict verdict = mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertEq(uint8(verdict), uint8(ISettlementHandler.Verdict.None));
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
        bytes32 id = _issue();
        _discard(id);

        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.LateReconciled));
        assertFalse(mc.isIssuancePaused(polygon), "a relocation asks no rule");
        assertEq(mc.positionOf(aliceId), BRIDGED_BALANCE, "a relocation moves no position");
    }

    function test_handleSettlement_Success_WhenALateLegIsReplayed() public {
        _track();
        bytes32 id = _issue();
        _discard(id);
        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        vm.expectCall(token, abi.encodeWithSelector(IToken.settleValidation.selector), 0);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ReplayedSettlement(id, polygon);
        vm.prank(token);
        ISettlementHandler.Verdict verdict = mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertEq(uint8(verdict), uint8(ISettlementHandler.Verdict.PauseChain));
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.LateReconciled));
    }

    function test_handleSettlement_Success_WhenTheChainIsAlreadyPausedOnALateLeg() public {
        _track();
        bytes32 id = _issue();
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
        bytes32 id = _issueCrossChain();
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
        bytes32 id = _issueCrossChain();
        _discard(id);
        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, "", 50));

        bytes32[] memory ids = new bytes32[](1);
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
        bytes32 id = _issue();
        assertEq(mc.pendingInOf(bobId), 90, "reserved at the maximum");
        assertEq(mc.pendingOutOf(aliceId), 90);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending), "reserved while pending");

        vm.expectCall(token, abi.encodeCall(IToken.settleValidation, (fromSat, toSat, 50, id)), 1);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.SettlementNotified(polygon, id, fromSat, toSat, 50);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ValidationSettled(id, polygon, 50);
        vm.prank(token);
        ISettlementHandler.Verdict verdict = mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertEq(uint8(verdict), uint8(ISettlementHandler.Verdict.None));
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
        bytes32 id = _issue();

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

    /// @notice A settlement always moves the positions, and always tells the trackers. There is no mode in
    ///         which the compliance applies a movement without recording who now owns the tokens.
    function test_handleSettlement_Success_WhenPositionsMoveAndModulesAreTold() public {
        address recorder = _bindAfterTransferModule();
        _track();
        bytes32 id = _issue();

        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(mc.positionOf(bobId), 50, "the recipient now holds what was executed");
        assertEq(mc.positionOf(aliceId), BRIDGED_BALANCE - 50, "and the sender that much less");
        assertEq(RecordingModule(recorder).transferActionCalls(), 1, "the trackers are told");
    }

    /// @notice A settlement on either end of the issued range is accepted: the bounds are inclusive.
    function test_handleSettlement_Success_WhenTheAmountIsOnABound() public {
        _track();
        bytes32 first = _issue();
        // The first validation reserved its maximum against the sending wallet, so the second can only be
        // issued for what is left of it.
        bytes32 second = _issue();
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
        bytes32 id = mc.requestTransferValidation(fromSat, nativeBob, 10, 40, "", _salt());

        vm.expectCall(token, abi.encodeCall(IToken.settleValidation, (fromSat, nativeBob, 40, id)), 1);
        vm.prank(token);
        ISettlementHandler.Verdict verdict = mc.handleSettlement(polygon, _leg(id, fromSat, nativeBob, 40));

        assertEq(uint8(verdict), uint8(ISettlementHandler.Verdict.None));
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(mc.positionOf(bobId), 40);
        (,,,, bytes32 toWallet,,,,,,) = TrackerOnlyModule(recorder).lastContext();
        assertEq(toWallet, bytes32(uint256(uint160(bob))), "a native wallet is its padded address");
    }

    function test_handleSettlement_Success_WhenTheLegClaimsTheReferenceChain() public {
        vm.prank(aliceIdentity);
        bytes32 id = mc.requestTransferValidation(fromSat, nativeBob, 10, 40, "", _salt());

        vm.prank(token);
        _assertRejected(id, _evmChainKey(block.chainid), _leg(id, fromSat, nativeBob, 40));

        _assertUntouched(id);
    }

    function test_handleSettlement_Success_WhenPastTheReleaseDeadlineBeforeAnyDiscard() public {
        _track();
        bytes32 id = _issue();
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Expired));

        vm.prank(token);
        ISettlementHandler.Verdict verdict = mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertEq(uint8(verdict), uint8(ISettlementHandler.Verdict.None));
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertFalse(mc.isIssuancePaused(polygon));
        assertEq(mc.pendingInOf(bobId), 0, "the reservation was still live and is released");
        assertEq(mc.positionOf(bobId), 50);
    }

    function test_handleSettlement_Success_WhenAModuleBoundAfterIssuanceSeesTheSettlement() public {
        _track();
        bytes32 id = _issue();
        address recorder = _bindAfterTransferModule();

        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertEq(RecordingModule(recorder).transferActionCalls(), 1);
        (, address fromIdentity, address toIdentity,,,,,,,,) = TrackerOnlyModule(recorder).lastContext();
        assertEq(fromIdentity, aliceIdentity, "the settlement knows whose it is");
        assertEq(toIdentity, bobIdentity);
        assertEq(mc.positionOf(bobId), 50);
    }

    /* ----- Replays ----- */

    function test_handleSettlement_Success_WhenAConsumedLegIsReplayed() public {
        _track();
        address recorder = _bindAfterTransferModule();
        bytes32 id = _issue();
        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        vm.expectCall(token, abi.encodeWithSelector(IToken.settleValidation.selector), 0);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ReplayedSettlement(id, polygon);
        vm.prank(token);
        ISettlementHandler.Verdict verdict = mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertEq(uint8(verdict), uint8(ISettlementHandler.Verdict.PauseChain));
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(mc.validationOf(id).executedAmount, 50);
        assertEq(RecordingModule(recorder).transferActionCalls(), 1, "nothing applied twice");
        assertEq(mc.positionOf(bobId), 50);
    }

    /* ----- Parked legs ----- */

    /// @notice A leg for an id with no issued body is parked under its id and chain, the chain paused, and
    ///         nothing recorded under the id. A second leg from the same chain is a replay.
    function test_handleSettlement_Success_WhenTheIdWasNeverIssued() public {
        bytes32 unknown = keccak256("an id this compliance never issued");
        MessageTypesLib.SettlementNotification memory leg = _legUnder(unknown, fromSat, toSat, 50, keccak256("body"));

        vm.expectCall(token, abi.encodeWithSelector(IToken.settleValidation.selector), 0);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.SettlementParked(unknown, polygon, 50, leg.hash);
        vm.prank(token);
        ISettlementHandler.Verdict verdict = mc.handleSettlement(polygon, leg);

        assertEq(uint8(verdict), uint8(ISettlementHandler.Verdict.PauseChain));
        ITransferValidation.ParkedLeg memory parked = mc.parkedLegOf(unknown, polygon);
        assertTrue(parked.exists);
        assertEq(parked.from, fromSat);
        assertEq(parked.to, toSat);
        assertEq(parked.amount, 50);
        assertEq(parked.hash, leg.hash);
        assertEq(mc.validationOf(unknown).fromIdentity, address(0), "the unknown id recorded nothing");
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownValidation.selector, unknown));
        mc.statusOf(unknown);

        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ReplayedSettlement(unknown, polygon);
        vm.prank(token);
        assertEq(uint8(mc.handleSettlement(polygon, leg)), uint8(ISettlementHandler.Verdict.PauseChain));
        assertEq(mc.parkedLegOf(unknown, polygon).amount, 50, "the first leg stays");

        // The other chain of a pair parks its own leg.
        vm.prank(token);
        mc.handleSettlement(optimism, _legUnder(unknown, "", toOptimism, 50, keccak256("body")));
        assertTrue(mc.parkedLegOf(unknown, optimism).exists);

        // The zero id is no exception.
        vm.prank(token);
        assertEq(
            uint8(mc.handleSettlement(polygon, _legUnder(bytes32(0), fromSat, toSat, 50, bytes32(0)))),
            uint8(ISettlementHandler.Verdict.PauseChain)
        );
    }

    /// @notice The request sent again with the same salt issues the same id and settles the parked leg instead
    ///         of sending the leg to a chain that already executed it.
    function test_requestTransferValidation_Success_WhenItSettlesTheLegParkedUnderItsId() public {
        _track();
        bytes32 salt = _salt();
        bytes32 id = _validationId(fromSat, salt);
        bytes32 executedUnder = keccak256("the body the dropped issuance sent");
        vm.prank(token);
        mc.handleSettlement(polygon, _legUnder(id, fromSat, toSat, 50, executedUnder));

        vm.expectCall(token, abi.encodeWithSelector(Token.dispatchComplianceValidation.selector), 0);
        vm.expectCall(token, abi.encodeWithSelector(IToken.applyVerdict.selector), 0);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.SettlementBodyDiverged(id, polygon, executedUnder);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ParkedLegSettled(id, polygon);
        vm.prank(aliceIdentity);
        assertEq(mc.requestTransferValidation(fromSat, toSat, 10, 90, "", salt), id);

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(mc.validationOf(id).executedAmount, 50);
        assertFalse(mc.parkedLegOf(id, polygon).exists);
        assertEq(mc.positionOf(bobId), 50);
        assertEq(mc.pendingInOf(bobId), 0);
    }

    /// @notice A parked leg outside the re-issued terms gets, at issuance, the verdict it would have got at
    ///         delivery: the body it executed was orphaned, the validation ends there, and the token is told to
    ///         pause the chain.
    function test_requestTransferValidation_Success_WhenTheParkedLegFallsOutsideTheReissuedTerms() public {
        bytes32 salt = _salt();
        bytes32 id = _validationId(fromSat, salt);
        bytes32 executedUnder = keccak256("a wider body");
        vm.prank(token);
        mc.handleSettlement(polygon, _legUnder(id, fromSat, toSat, 95, executedUnder));

        vm.expectCall(token, abi.encodeCall(IToken.applyVerdict, (polygon, ISettlementHandler.Verdict.PauseChain)), 1);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ValidationOrphaned(id, polygon, 95, executedUnder);
        vm.prank(aliceIdentity);
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "", salt);

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Orphaned));
        assertFalse(mc.parkedLegOf(id, polygon).exists);
        assertEq(mc.pendingInOf(bobId), 0, "released");
        assertEq(TokenReservationStub(token).reservedOf(fromSat), 0);
    }

    /// @notice On a pair, the leg of the chain that reported is settled and only the other chain is sent to.
    function test_requestTransferValidation_Success_WhenOneLegOfAPairIsParked() public {
        bytes32 salt = _salt();
        bytes32 id = _validationId(fromSat, salt);
        vm.prank(token);
        mc.handleSettlement(polygon, _legUnder(id, fromSat, "", 50, keccak256("body")));

        vm.expectCall(token, abi.encodeWithSelector(Token.dispatchComplianceValidation.selector), 1);
        vm.expectCall(token, abi.encodeWithSelector(Token.dispatchComplianceValidation.selector, optimism, id), 1);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ParkedLegSettled(id, polygon);
        vm.prank(aliceIdentity);
        mc.requestTransferValidation(fromSat, toOptimism, 10, 90, "", salt);

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingMint));
        assertEq(mc.validationOf(id).executedAmount, 50);
    }

    /* ----- Two legs ----- */

    function test_handleSettlement_Success_WhenTheBurnLegLandsFirst() public {
        _track();
        address recorder = _bindAfterTransferModule();
        bytes32 id = _issueCrossChain();

        vm.expectCall(token, abi.encodeCall(IToken.holdInTransit, (fromSat, 50, id, 90)), 1);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ValidationLegConfirmed(id, polygon, 50);
        vm.prank(token);
        ISettlementHandler.Verdict verdict = mc.handleSettlement(polygon, _leg(id, fromSat, "", 50));

        assertEq(uint8(verdict), uint8(ISettlementHandler.Verdict.None));
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
        verdict = mc.handleSettlement(optimism, _leg(id, "", toOptimism, 50));

        assertEq(uint8(verdict), uint8(ISettlementHandler.Verdict.None));
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(RecordingModule(recorder).transferActionCalls(), 1);
        assertEq(mc.pendingInOf(bobId), 0);
        assertEq(mc.positionOf(bobId), 50);
        assertEq(mc.positionOf(aliceId), BRIDGED_BALANCE - 50);
    }

    function test_handleSettlement_Success_WhenTheMintLegLandsFirst() public {
        _track();
        bytes32 id = _issueCrossChain();

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
        bytes32 id = _issueCrossChain();
        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, "", 50));

        vm.warp(ISSUED_AT + VALIDITY_WINDOW + OPTIMISM_WINDOW + 30 days);

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingMint));
    }

    function test_handleSettlement_Success_WhenAConsumedLegOfTwoIsReplayed() public {
        bytes32 id = _issueCrossChain();
        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, "", 50));

        vm.expectCall(token, abi.encodeWithSelector(IToken.settleValidation.selector), 0);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ReplayedSettlement(id, polygon);
        vm.prank(token);
        ISettlementHandler.Verdict verdict = mc.handleSettlement(polygon, _leg(id, fromSat, "", 50));

        assertEq(uint8(verdict), uint8(ISettlementHandler.Verdict.PauseChain));
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingMint));
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingMint));
    }

    function test_handleSettlement_RevertWhen_TheSecondLegCarriesAnotherAmount() public {
        bytes32 id = _issueCrossChain();
        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, "", 50));

        vm.prank(token);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementAmountMismatch.selector, id, 50, 51));
        mc.handleSettlement(optimism, _leg(id, "", toOptimism, 51));

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingMint));
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingMint));
    }

    function test_handleSettlement_Success_WhenATwoLegValidationGetsAMismatchedLeg() public {
        bytes32 id = _issueCrossChain();

        vm.startPrank(token);
        _assertRejected(id, polygon, _leg(id, fromSat, toOptimism, 50));
        _assertRejected(id, optimism, _leg(id, fromSat, "", 50));
        _assertRejected(id, polygon, _leg(id, "", toOptimism, 50));
        _assertRejected(id, polygon, _leg(id, "", "", 50));
        _assertRejected(id, optimism, _leg(id, "", carolSat, 50));
        vm.stopPrank();

        _assertUntouched(id);
    }

    function _discard(bytes32 id) private {
        vm.warp(block.timestamp + VALIDITY_WINDOW + OPTIMISM_WINDOW + 1);
        bytes32[] memory ids = new bytes32[](1);
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

    function _issueCrossChain() private returns (bytes32 id) {
        vm.prank(aliceIdentity);
        id = mc.requestTransferValidation(fromSat, toOptimism, 10, 90, "", _salt());
    }

    function _issue() private returns (bytes32 id) {
        vm.prank(aliceIdentity);
        id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());
    }

    /// @dev A leg carrying the issued hash: what a Lite that executed the issued body reports.
    function _leg(bytes32 id, bytes memory from, bytes memory to, uint256 amount)
        private
        view
        returns (MessageTypesLib.SettlementNotification memory)
    {
        return _legUnder(id, from, to, amount, _issuedHash(id));
    }

    /// @dev A leg carrying `hash`: what a Lite that executed another body reports.
    function _legUnder(bytes32 id, bytes memory from, bytes memory to, uint256 amount, bytes32 hash)
        private
        pure
        returns (MessageTypesLib.SettlementNotification memory)
    {
        return MessageTypesLib.SettlementNotification({
            validationId: id, from: from, to: to, amount: amount, hash: hash
        });
    }

    /// @dev A leg outside the issued terms under the issued hash: rejected with the chain paused. Runs under the
    ///  caller's prank.
    function _assertRejected(bytes32 id, bytes32 chainKey, MessageTypesLib.SettlementNotification memory leg) private {
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.SettlementRejected(id, chainKey, leg.amount, leg.hash);
        assertEq(uint8(mc.handleSettlement(chainKey, leg)), uint8(ISettlementHandler.Verdict.PauseChain));
    }

    function _assertUntouched(bytes32 id) private view {
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
