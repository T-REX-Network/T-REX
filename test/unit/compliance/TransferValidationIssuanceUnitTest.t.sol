// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ModularComplianceBaseUnitTest } from "./helpers/ModularComplianceBaseUnitTest.t.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "contracts/libraries/WalletKeyLib.sol";
import { Token } from "contracts/token/Token.sol";
import {
    CappedRecipientModule,
    RecordingModule,
    RuleOnlyModule,
    WritingRuleModule
} from "test/integration/mocks/CapabilityModules.sol";
import { TokenReservationStub } from "test/unit/compliance/helpers/TokenReservationStub.sol";

/// @dev The issuance engine on a mocked token and registry: who may ask, what is refused before any write, how
///      the range is capped, what is recorded and what leaves toward which chain.
contract TransferValidationIssuanceUnitTest is ModularComplianceBaseUnitTest {

    uint256 internal constant POLYGON = 137;
    uint256 internal constant OPTIMISM = 10;
    uint256 internal constant ARBITRUM = 42_161;
    uint64 internal constant VALIDITY_WINDOW = 1 hours;
    uint64 internal constant POLYGON_WINDOW = 30 minutes;
    uint64 internal constant OPTIMISM_WINDOW = 45 minutes;
    uint256 internal constant BRIDGED_BALANCE = 100;

    bytes32 internal polygon = _evmChainKey(POLYGON);
    bytes32 internal optimism = _evmChainKey(OPTIMISM);
    bytes32 internal arbitrum = _evmChainKey(ARBITRUM);
    bytes32 internal referenceChain;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal satelliteAlice = makeAddr("aliceOnPolygon");
    address internal satelliteBob = makeAddr("bobOnSatellites");
    address internal aliceIdentity = makeAddr("AliceIdentity");
    address internal bobIdentity = makeAddr("BobIdentity");

    bytes internal fromSat;
    bytes internal toSat;
    bytes internal toOptimism;
    bytes internal toArbitrum;
    bytes internal nativeAlice;
    bytes internal nativeBob;

    function setUp() public override {
        super.setUp();
        referenceChain = _evmChainKey(block.chainid);
        fromSat = InteroperableAddress.formatEvmV1(POLYGON, satelliteAlice);
        toSat = InteroperableAddress.formatEvmV1(POLYGON, satelliteBob);
        toOptimism = InteroperableAddress.formatEvmV1(OPTIMISM, satelliteBob);
        toArbitrum = InteroperableAddress.formatEvmV1(ARBITRUM, satelliteBob);
        nativeAlice = InteroperableAddress.formatEvmV1(block.chainid, alice);
        nativeBob = InteroperableAddress.formatEvmV1(block.chainid, bob);

        mc.setReconciliationWindow(polygon, POLYGON_WINDOW);
        mc.setReconciliationWindow(optimism, OPTIMISM_WINDOW);

        vm.mockCall(token, abi.encodeWithSignature("identityRegistry()"), abi.encode(registry));
        // The wallet's room lives on the token now, and these tests are about it accumulating, so the mocked
        // token address gets a stub with real arithmetic. `vm.mockCall` still wins over etched code for the
        // selectors mocked below, so only the reservation calls actually reach the stub.
        vm.etch(token, address(new TokenReservationStub()).code);
        TokenReservationStub(token).setBridgedBalance(fromSat, BRIDGED_BALANCE);
        vm.mockCall(token, abi.encodeWithSelector(Token.dispatchComplianceValidation.selector), abi.encode(bytes32(0)));

        _bind(fromSat, aliceIdentity);
        _bind(toSat, bobIdentity);
        _bind(toOptimism, bobIdentity);
        _bind(toArbitrum, bobIdentity);
        _bind(nativeBob, bobIdentity);
    }

    modifier configured() {
        mc.setDefaultValidityWindow(VALIDITY_WINDOW);
        _;
    }

    // ==== authorization Tests ====

    function test_requestTransferValidation_Success_WhenCalledByTheIdentity() public configured {
        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");

        assertEq(id, 1);
        assertEq(mc.lastValidationId(), 1);
    }

    function test_requestTransferValidation_Success_WhenCalledByAnAgent() public configured {
        vm.prank(agentAccount);
        uint256 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");

        assertEq(id, 1);
    }

    function test_requestTransferValidation_RevertWhen_CallerIsAStranger() public configured {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAuthorizedForWallet.selector, stranger, fromSat));
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "");
    }

    /// @notice A satellite wallet's own address proves nothing on this chain.
    function test_requestTransferValidation_RevertWhen_SatelliteWalletCallsForItself() public configured {
        vm.prank(satelliteAlice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAuthorizedForWallet.selector, satelliteAlice, fromSat));
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "");
    }

    // ==== preconditions Tests ====

    function test_requestTransferValidation_RevertWhen_RangeIsInverted() public configured {
        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidRequestedRange.selector, 20, 10));
        mc.requestTransferValidation(fromSat, toSat, 20, 10, "");
    }

    /// @notice A native position is free to leave between issuance and settlement, so no satellite can be
    ///         authorized to move it: it reaches a satellite through delegation-out, which burns first.
    function test_requestTransferValidation_RevertWhen_TheSenderIsNative() public configured {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SenderNotOnSatellite.selector, nativeAlice));
        mc.requestTransferValidation(nativeAlice, toSat, 10, 40, "");

        assertEq(mc.lastValidationId(), 0);
    }

    function test_requestTransferValidation_RevertWhen_BothWalletsAreNative() public configured {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SenderNotOnSatellite.selector, nativeAlice));
        mc.requestTransferValidation(nativeAlice, nativeBob, 10, 40, "");
    }

    function test_requestTransferValidation_RevertWhen_SpenderIsNotCanonical() public configured {
        bytes memory padded = abi.encodePacked(toSat, hex"00");
        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded));
        mc.requestTransferValidation(fromSat, toSat, 10, 90, padded);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, hex"deadbeef"));
        mc.requestTransferValidation(fromSat, toSat, 10, 90, hex"deadbeef");
    }

    function test_requestTransferValidation_RevertWhen_EnvelopeIsNotCanonical() public configured {
        bytes memory padded = abi.encodePacked(toSat, hex"00");
        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded));
        mc.requestTransferValidation(fromSat, padded, 10, 90, "");
    }

    function test_requestTransferValidation_RevertWhen_ValidityWindowIsNotSet() public {
        vm.prank(aliceIdentity);
        vm.expectRevert(ErrorsLib.ValidityWindowNotSet.selector);
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "");
    }

    function test_requestTransferValidation_RevertWhen_ReconciliationWindowIsNotSet() public configured {
        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ReconciliationWindowNotSet.selector, arbitrum));
        mc.requestTransferValidation(fromSat, toArbitrum, 10, 90, "");
    }

    function test_requestTransferValidation_RevertWhen_FromChainIsPaused() public configured {
        mc.setIssuancePaused(polygon, true);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationIssuancePaused.selector, polygon));
        mc.requestTransferValidation(fromSat, toOptimism, 10, 90, "");
    }

    function test_requestTransferValidation_RevertWhen_ToChainIsPaused() public configured {
        mc.setIssuancePaused(optimism, true);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationIssuancePaused.selector, optimism));
        mc.requestTransferValidation(fromSat, toOptimism, 10, 90, "");
    }

    function test_requestTransferValidation_Success_AfterTheChainIsUnpaused() public configured {
        mc.setIssuancePaused(polygon, true);
        mc.setIssuancePaused(polygon, false);

        vm.prank(aliceIdentity);
        assertEq(mc.requestTransferValidation(fromSat, toSat, 10, 90, ""), 1);
    }

    // ==== eligibility Tests ====

    function test_requestTransferValidation_RevertWhen_FromIsUnbound() public configured {
        _bind(fromSat, address(0));

        vm.prank(agentAccount);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnverifiedWallet.selector, fromSat));
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "");
    }

    function test_requestTransferValidation_RevertWhen_ToIsNotVerified() public configured {
        vm.mockCall(registry, abi.encodeWithSignature("isWalletVerified(bytes)", toSat), abi.encode(false));

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnverifiedWallet.selector, toSat));
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "");
    }

    // ==== bounds Tests ====

    function test_requestTransferValidation_Success_WhenCappingAtTheBridgedBalance() public configured {
        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(fromSat, toSat, 90, 110, "");

        ITransferValidation.Validation memory record = mc.validationOf(id);
        assertEq(record.amountMin, 90);
        assertEq(record.amountMax, BRIDGED_BALANCE);
    }

    function test_requestTransferValidation_Success_WhenTheRequestIsInsideTheBalance() public configured {
        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(fromSat, toSat, 9, 11, "");

        ITransferValidation.Validation memory record = mc.validationOf(id);
        assertEq(record.amountMin, 9);
        assertEq(record.amountMax, 11);
    }

    function test_requestTransferValidation_RevertWhen_RequestedMinIsAboveTheBalance() public configured {
        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 150, BRIDGED_BALANCE));
        mc.requestTransferValidation(fromSat, toSat, 150, 200, "");

        assertEq(mc.lastValidationId(), 0);
    }

    /// @notice A validation authorizing nothing is never issued, whichever step made the maximum zero.
    function test_requestTransferValidation_RevertWhen_TheMaximumIsZero() public configured {
        vm.prank(aliceIdentity);
        vm.expectRevert(ErrorsLib.ZeroValue.selector);
        mc.requestTransferValidation(fromSat, toSat, 0, 0, "");

        TokenReservationStub(token).setBridgedBalance(fromSat, 0);
        vm.prank(aliceIdentity);
        vm.expectRevert(ErrorsLib.ZeroValue.selector);
        mc.requestTransferValidation(fromSat, toSat, 0, 90, "");

        assertEq(mc.lastValidationId(), 0);
    }

    /// @notice Two wallets of one identity: issued, recorded, but no module consulted.
    function test_requestTransferValidation_Success_WhenBothWalletsBelongToOneIdentity() public configured {
        address module = _bindAllowedAmountModule();
        RecordingModule(module).setAllowedAmount(5);
        _bind(toSat, aliceIdentity);

        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");

        ITransferValidation.Validation memory record = mc.validationOf(id);
        assertEq(record.amountMin, 10);
        assertEq(record.amountMax, 90);
        assertEq(record.fromIdentity, aliceIdentity);
        assertEq(record.toIdentity, aliceIdentity);
    }

    function test_requestTransferValidation_Success_WhenAModuleNarrowsTheMaximum() public configured {
        address module = _bindAllowedAmountModule();
        RecordingModule(module).setAllowedAmount(60);

        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");

        ITransferValidation.Validation memory record = mc.validationOf(id);
        assertEq(record.amountMin, 10);
        assertEq(record.amountMax, 60);
        assertEq(record.fromIdentity, aliceIdentity);
        assertEq(record.toIdentity, bobIdentity);
    }

    function test_requestTransferValidation_Success_WhenTheSmallestAnswerWins() public configured {
        RecordingModule(_bindAllowedAmountModule()).setAllowedAmount(60);
        RecordingModule(_bindAllowedAmountModule()).setAllowedAmount(30);
        RecordingModule(_bindAllowedAmountModule()).setAllowedAmount(80);

        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");

        assertEq(mc.validationOf(id).amountMax, 30);
    }

    function test_requestTransferValidation_Success_WhenAModuleAnswersNoLimit() public configured {
        _bindAllowedAmountModule();

        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");

        assertEq(mc.validationOf(id).amountMax, 90);
    }

    function test_requestTransferValidation_RevertWhen_AModuleEmptiesTheRange() public configured {
        address module = _bindAllowedAmountModule();
        RecordingModule(module).setAllowedAmount(5);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 10, 5));
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "");
    }

    function test_requestTransferValidation_RevertWhen_AModuleRefuses() public configured {
        RecordingModule(_bindAllowedAmountModule()).setAllow(false);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 10, 0));
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "");

        vm.prank(aliceIdentity);
        vm.expectRevert(ErrorsLib.ZeroValue.selector);
        mc.requestTransferValidation(fromSat, toSat, 0, 90, "");
    }

    function test_requestTransferValidation_RevertWhen_AModuleWritesInAllowedAmount() public configured {
        address module = address(new WritingRuleModule());
        mc.addModule(module);

        vm.prank(aliceIdentity);
        vm.expectRevert();
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "");

        assertEq(WritingRuleModule(module).writes(), 0);
        assertEq(mc.lastValidationId(), 0);
    }

    /// @notice A named spender is carried on the wire for the satellite to enforce, not resolved here: a
    ///         spender policy is about who moves the tokens, and the satellite is where that call happens.
    ///         The envelope must still parse, which is what keeps an unusable one out of the record.
    function test_requestTransferValidation_Success_WhenTheSpenderIsUnknownHere() public configured {
        bytes memory spender = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("spender"));
        _bind(spender, address(0));
        _bindAllowedAmountModule();

        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, spender);

        assertEq(mc.validationOf(id).amountMax, 90);
    }

    function test_requestTransferValidation_Success_WhenTheSpenderResolves() public configured {
        bytes memory spender = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("spender"));
        _bind(spender, makeAddr("SpenderIdentity"));
        _bindAllowedAmountModule();

        vm.prank(aliceIdentity);
        assertEq(mc.requestTransferValidation(fromSat, toSat, 10, 90, spender), 1);
    }

    /* ----- The reservation ----- */

    function test_requestTransferValidation_Success_WhenReservingThePendingAmounts() public configured {
        _track();

        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");

        assertFalse(mc.validationOf(id).relocation, "reserved against the identities");
        assertEq(mc.pendingOutOf(aliceIdentity), 90);
        assertEq(mc.pendingInOf(bobIdentity), 90);
        assertEq(TokenReservationStub(token).reservedOf(fromSat), 90);
        assertEq(mc.positionOf(aliceIdentity), BRIDGED_BALANCE);
        assertEq(mc.positionOf(bobIdentity), 0);
    }

    function test_requestTransferValidation_Success_WhenReservationsAccumulate() public configured {
        _track();

        vm.startPrank(aliceIdentity);
        mc.requestTransferValidation(fromSat, toSat, 10, 30, "");
        mc.requestTransferValidation(fromSat, toOptimism, 10, 40, "");
        vm.stopPrank();

        assertEq(mc.pendingOutOf(aliceIdentity), 70);
        assertEq(mc.pendingInOf(bobIdentity), 70);
        assertEq(TokenReservationStub(token).reservedOf(fromSat), 70);
    }

    function test_requestTransferValidation_Success_WhenPendingOutOfTheWalletCapsTheNext() public configured {
        _track();

        vm.startPrank(aliceIdentity);
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "");
        uint256 second = mc.requestTransferValidation(fromSat, toSat, 5, 90, "");
        vm.stopPrank();

        assertEq(mc.validationOf(second).amountMax, BRIDGED_BALANCE - 90);
        assertEq(TokenReservationStub(token).reservedOf(fromSat), 100);

        vm.prank(aliceIdentity);
        vm.expectRevert(ErrorsLib.ZeroValue.selector);
        mc.requestTransferValidation(fromSat, toSat, 0, 90, "");
    }

    function test_requestTransferValidation_Success_WhenOneIdentityReservesNothing() public configured {
        _track();
        _bind(toSat, aliceIdentity);

        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");

        // Nothing is reserved against the identity: relocating your own tokens changes no position, so it
        // must not eat your own room. The wallet's share is still written, because the wallet can only ever
        // send what it holds, whoever owns the far side.
        assertTrue(mc.validationOf(id).relocation, "a relocation reserves nothing against the identity");
        assertEq(mc.pendingOutOf(aliceIdentity), 0);
        assertEq(mc.pendingInOf(aliceIdentity), 0);
        assertEq(TokenReservationStub(token).reservedOf(fromSat), 90);
    }

    /// @notice The wallet's share of a reservation is written on every issuance, whatever the identities do:
    ///         it is what stops a second validation drawing more than the wallet can cover.
    function test_requestTransferValidation_Success_WhenTheWalletShareIsAlwaysReserved() public configured {
        _track();

        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
        assertEq(TokenReservationStub(token).reservedOf(fromSat), 90);
    }

    function test_requestTransferValidation_Success_WhenTwoValidationsRaceForOneCap() public configured {
        _track();
        address capped = _bindCappedModule(50);

        vm.startPrank(aliceIdentity);
        uint256 first = mc.requestTransferValidation(fromSat, toSat, 10, 30, "");
        uint256 second = mc.requestTransferValidation(fromSat, toOptimism, 10, 90, "");
        vm.stopPrank();

        assertEq(mc.validationOf(first).amountMax, 30);
        assertEq(mc.validationOf(second).amountMax, 20, "the second sees the first as executed at its maximum");
        assertEq(CappedRecipientModule(capped).capOf(address(mc)), 50);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 1, 0));
        mc.requestTransferValidation(fromSat, toSat, 1, 90, "");
    }

    /// @notice A rule that decides from positions binds anywhere, with nothing to set up first: the
    ///         compliance keeps every position from the token's first mint, so the numbers it reads always
    ///         exist. Under the previous design such a module had to be refused until tracking was enabled.
    function test_addModule_Success_WhenAReaderOfPositionsBinds() public configured {
        address module = _deployCappedModule();

        mc.addModule(module);

        assertTrue(mc.isModuleBound(module));
    }

    // ==== record, event and dispatch Tests ====

    function test_requestTransferValidation_Success_WhenIdsIncreaseAndNeverRepeat() public configured {
        vm.startPrank(aliceIdentity);
        uint256 first = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");
        uint256 second = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");
        vm.stopPrank();

        assertEq(first, 1);
        assertEq(second, 2);
        assertEq(mc.lastValidationId(), 2);
        assertTrue(mc.validationOf(first).hash != mc.validationOf(second).hash);
    }

    function test_requestTransferValidation_Success_WhenSnapshottingTheDeadlines() public configured {
        vm.warp(1_700_000_000);

        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");

        ITransferValidation.Validation memory record = mc.validationOf(id);
        assertEq(record.expiry, 1_700_000_000 + VALIDITY_WINDOW);
        assertEq(record.releaseAt, 1_700_000_000 + VALIDITY_WINDOW + POLYGON_WINDOW);
        assertEq(record.fromChainKey, polygon);
        assertEq(record.toChainKey, polygon);

        // A later change of the windows never moves the deadline of an outstanding validation.
        mc.setReconciliationWindow(polygon, 2 hours);
        assertEq(mc.validationOf(id).releaseAt, 1_700_000_000 + VALIDITY_WINDOW + POLYGON_WINDOW);
    }

    function test_requestTransferValidation_Success_WhenCrossChainTakesTheLargerWindow() public configured {
        vm.warp(1_700_000_000);

        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(fromSat, toOptimism, 10, 90, "");

        ITransferValidation.Validation memory record = mc.validationOf(id);
        assertEq(record.releaseAt, 1_700_000_000 + VALIDITY_WINDOW + OPTIMISM_WINDOW);
        assertEq(record.fromChainKey, polygon);
        assertEq(record.toChainKey, optimism);
    }

    function test_requestTransferValidation_Success_WhenTheNativeRecipientKeepsTheReferenceKey() public configured {
        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(fromSat, nativeBob, 10, 40, "");

        ITransferValidation.Validation memory record = mc.validationOf(id);
        assertEq(record.fromChainKey, polygon);
        assertEq(record.toChainKey, referenceChain);
        assertEq(record.fromKey, WalletKeyLib.canonicalKey(fromSat));
        assertEq(record.toKey, WalletKeyLib.canonicalKey(nativeBob));
        assertFalse(record.twoLegs);
    }

    function test_requestTransferValidation_Success_WhenRecordingTheWalletKeysAndTheLegCount() public configured {
        vm.startPrank(aliceIdentity);
        uint256 sameChain = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");
        uint256 crossChain = mc.requestTransferValidation(fromSat, toOptimism, 10, 90, "");
        vm.stopPrank();

        ITransferValidation.Validation memory record = mc.validationOf(sameChain);
        assertEq(record.fromKey, WalletKeyLib.canonicalKey(fromSat));
        assertEq(record.toKey, WalletKeyLib.canonicalKey(toSat));
        assertFalse(record.twoLegs);

        record = mc.validationOf(crossChain);
        assertEq(record.fromKey, WalletKeyLib.canonicalKey(fromSat));
        assertEq(record.toKey, WalletKeyLib.canonicalKey(toOptimism));
        assertTrue(record.twoLegs);
    }

    function test_requestTransferValidation_Success_WhenTheEventAndRecordMatchTheObject() public configured {
        vm.warp(1_700_000_000);
        bytes memory spender = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("spender"));
        _bind(spender, makeAddr("SpenderIdentity"));
        MessageTypesLib.ComplianceValidation memory expected =
            _expected(1, fromSat, toSat, spender, 10, 90, POLYGON_WINDOW);

        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.TransferValidationIssued(1, fromSat, toSat, spender, 10, 90, expected.expiry, POLYGON_WINDOW);
        vm.prank(aliceIdentity);
        mc.requestTransferValidation(fromSat, toSat, 10, 90, spender);

        assertEq(mc.validationOf(1).hash, MessageTypesLib.hashValidation(expected));
    }

    function test_requestTransferValidation_Success_WhenDispatchingOneLegForASameChainMovement() public configured {
        vm.warp(1_700_000_000);
        MessageTypesLib.ComplianceValidation memory expected = _expected(1, fromSat, toSat, "", 10, 90, POLYGON_WINDOW);

        vm.expectCall(token, abi.encodeCall(Token.dispatchComplianceValidation, (polygon, 1, abi.encode(expected))), 1);
        vm.expectCall(token, abi.encodeWithSelector(Token.dispatchComplianceValidation.selector), 1);
        vm.prank(aliceIdentity);
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "");
    }

    function test_requestTransferValidation_Success_WhenDispatchingTwoLegsForACrossChainMovement() public configured {
        vm.warp(1_700_000_000);
        MessageTypesLib.ComplianceValidation memory expected =
            _expected(1, fromSat, toOptimism, "", 10, 90, OPTIMISM_WINDOW);
        bytes memory body = abi.encode(expected);

        vm.expectCall(token, abi.encodeCall(Token.dispatchComplianceValidation, (polygon, 1, body)), 1);
        vm.expectCall(token, abi.encodeCall(Token.dispatchComplianceValidation, (optimism, 1, body)), 1);
        vm.prank(aliceIdentity);
        mc.requestTransferValidation(fromSat, toOptimism, 10, 90, "");
    }

    function test_requestTransferValidation_Success_WhenDispatchingToTheSatelliteSideOnly() public configured {
        vm.expectCall(token, abi.encodeWithSelector(Token.dispatchComplianceValidation.selector, polygon, 1), 1);
        vm.expectCall(token, abi.encodeWithSelector(Token.dispatchComplianceValidation.selector), 1);
        vm.prank(aliceIdentity);
        mc.requestTransferValidation(fromSat, nativeBob, 10, 40, "");
    }

    /// @notice A dispatch the token refuses reverts the whole request, nothing recorded.
    function test_requestTransferValidation_RevertWhen_TheTokenRefusesTheDispatch() public configured {
        vm.mockCallRevert(
            token,
            abi.encodeWithSelector(Token.dispatchComplianceValidation.selector),
            abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon)
        );

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon));
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "");

        assertEq(mc.lastValidationId(), 0);
        assertEq(mc.validationOf(1).hash, bytes32(0));
    }

    function _expected(
        uint256 id,
        bytes memory from,
        bytes memory to,
        bytes memory spender,
        uint256 min,
        uint256 max,
        uint64 window
    ) private view returns (MessageTypesLib.ComplianceValidation memory) {
        return MessageTypesLib.ComplianceValidation({
            validationId: id,
            from: from,
            to: to,
            spender: spender,
            amountMin: min,
            amountMax: max,
            token: token,
            expiry: uint64(block.timestamp) + VALIDITY_WINDOW,
            reconciliationWindow: window
        });
    }

    function _bind(bytes memory wallet, address identity) private {
        vm.mockCall(registry, abi.encodeWithSignature("resolveIdentity(bytes)", wallet), abi.encode(identity));
        vm.mockCall(
            registry, abi.encodeWithSignature("isWalletVerified(bytes)", wallet), abi.encode(identity != address(0))
        );
    }

    function _bindAllowedAmountModule() private returns (address module) {
        module = address(new ModuleProxy(address(new RuleOnlyModule()), abi.encodeCall(RecordingModule.initialize, ())));
        mc.addModule(module);
    }

    function _deployCappedModule() private returns (address module) {
        module = address(
            new ModuleProxy(address(new CappedRecipientModule()), abi.encodeCall(RecordingModule.initialize, ()))
        );
    }

    function _bindCappedModule(uint256 cap) private returns (address module) {
        module = _deployCappedModule();
        mc.addModule(module);
        mc.callModuleFunction(abi.encodeCall(CappedRecipientModule.setCap, (cap)), module);
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

    function _evmChainKey(uint256 chainId) private pure returns (bytes32) {
        (bytes2 chainType, bytes memory chainReference,) =
            InteroperableAddress.parseV1(InteroperableAddress.formatEvmV1(chainId));
        return MessageTypesLib.chainKey(chainType, chainReference);
    }

}
