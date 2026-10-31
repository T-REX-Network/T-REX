// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ModularComplianceBaseUnitTest } from "./helpers/ModularComplianceBaseUnitTest.t.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ITREXMessaging } from "contracts/interop/ITREXMessaging.sol";
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
        vm.mockCall(token, abi.encodeWithSelector(ITREXMessaging.isInboundPaused.selector), abi.encode(false));

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
        bytes32 salt = _salt();
        vm.prank(aliceIdentity);
        bytes32 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "", salt);

        assertEq(id, _validationId(fromSat, salt));
        assertEq(mc.validationOf(id).fromIdentity, aliceIdentity);
    }

    function test_requestTransferValidation_Success_WhenCalledByAnAgent() public configured {
        vm.prank(agentAccount);
        bytes32 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());

        assertEq(mc.validationOf(id).fromIdentity, aliceIdentity);
    }

    function test_requestTransferValidation_RevertWhen_CallerIsAStranger() public configured {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAuthorizedForWallet.selector, stranger, fromSat));
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());
    }

    /// @notice A satellite wallet's own address proves nothing on this chain.
    function test_requestTransferValidation_RevertWhen_SatelliteWalletCallsForItself() public configured {
        vm.prank(satelliteAlice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAuthorizedForWallet.selector, satelliteAlice, fromSat));
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());
    }

    // ==== preconditions Tests ====

    function test_requestTransferValidation_RevertWhen_RangeIsInverted() public configured {
        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidRequestedRange.selector, 20, 10));
        mc.requestTransferValidation(fromSat, toSat, 20, 10, "", _salt());
    }

    /// @notice A native position is free to leave between issuance and settlement, so no satellite can be
    ///         authorized to move it: it reaches a satellite through delegation-out, which burns first.
    function test_requestTransferValidation_RevertWhen_TheSenderIsNative() public configured {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SenderNotOnSatellite.selector, nativeAlice));
        mc.requestTransferValidation(nativeAlice, toSat, 10, 40, "", _salt());

        _assertNothingRecorded(nativeAlice);
    }

    function test_requestTransferValidation_RevertWhen_BothWalletsAreNative() public configured {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SenderNotOnSatellite.selector, nativeAlice));
        mc.requestTransferValidation(nativeAlice, nativeBob, 10, 40, "", _salt());
    }

    function test_requestTransferValidation_RevertWhen_SpenderIsNotCanonical() public configured {
        bytes memory padded = abi.encodePacked(toSat, hex"00");
        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded));
        mc.requestTransferValidation(fromSat, toSat, 10, 90, padded, _salt());

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, hex"deadbeef"));
        mc.requestTransferValidation(fromSat, toSat, 10, 90, hex"deadbeef", _salt());
    }

    function test_requestTransferValidation_RevertWhen_EnvelopeIsNotCanonical() public configured {
        bytes memory padded = abi.encodePacked(toSat, hex"00");
        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded));
        mc.requestTransferValidation(fromSat, padded, 10, 90, "", _salt());
    }

    function test_requestTransferValidation_RevertWhen_ValidityWindowIsNotSet() public {
        vm.prank(aliceIdentity);
        vm.expectRevert(ErrorsLib.ValidityWindowNotSet.selector);
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());
    }

    function test_requestTransferValidation_RevertWhen_ReconciliationWindowIsNotSet() public configured {
        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ReconciliationWindowNotSet.selector, arbitrum));
        mc.requestTransferValidation(fromSat, toArbitrum, 10, 90, "", _salt());
    }

    function test_requestTransferValidation_RevertWhen_FromChainIsPaused() public configured {
        mc.setIssuancePaused(polygon, true);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationIssuancePaused.selector, polygon));
        mc.requestTransferValidation(fromSat, toOptimism, 10, 90, "", _salt());
    }

    function test_requestTransferValidation_RevertWhen_ToChainIsPaused() public configured {
        mc.setIssuancePaused(optimism, true);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationIssuancePaused.selector, optimism));
        mc.requestTransferValidation(fromSat, toOptimism, 10, 90, "", _salt());
    }

    function test_requestTransferValidation_Success_AfterTheChainIsUnpaused() public configured {
        mc.setIssuancePaused(polygon, true);
        mc.setIssuancePaused(polygon, false);

        bytes32 salt = _salt();
        vm.prank(aliceIdentity);
        assertEq(mc.requestTransferValidation(fromSat, toSat, 10, 90, "", salt), _validationId(fromSat, salt));
    }

    // ==== eligibility Tests ====

    function test_requestTransferValidation_RevertWhen_FromIsUnbound() public configured {
        _bind(fromSat, address(0));

        vm.prank(agentAccount);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnverifiedWallet.selector, fromSat));
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());
    }

    function test_requestTransferValidation_RevertWhen_ToIsNotVerified() public configured {
        vm.mockCall(registry, abi.encodeWithSignature("isWalletVerified(bytes)", toSat), abi.encode(false));

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnverifiedWallet.selector, toSat));
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());
    }

    // ==== bounds Tests ====

    function test_requestTransferValidation_Success_WhenCappingAtTheBridgedBalance() public configured {
        vm.prank(aliceIdentity);
        bytes32 id = mc.requestTransferValidation(fromSat, toSat, 90, 110, "", _salt());

        ITransferValidation.Validation memory record = mc.validationOf(id);
        assertEq(record.amountMin, 90);
        assertEq(record.amountMax, BRIDGED_BALANCE);
    }

    function test_requestTransferValidation_Success_WhenTheRequestIsInsideTheBalance() public configured {
        vm.prank(aliceIdentity);
        bytes32 id = mc.requestTransferValidation(fromSat, toSat, 9, 11, "", _salt());

        ITransferValidation.Validation memory record = mc.validationOf(id);
        assertEq(record.amountMin, 9);
        assertEq(record.amountMax, 11);
    }

    function test_requestTransferValidation_RevertWhen_RequestedMinIsAboveTheBalance() public configured {
        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 150, BRIDGED_BALANCE));
        mc.requestTransferValidation(fromSat, toSat, 150, 200, "", _salt());

        _assertNothingRecorded(fromSat);
    }

    /// @notice A validation authorizing nothing is never issued, whichever step made the maximum zero.
    function test_requestTransferValidation_RevertWhen_TheMaximumIsZero() public configured {
        vm.prank(aliceIdentity);
        vm.expectRevert(ErrorsLib.ZeroValue.selector);
        mc.requestTransferValidation(fromSat, toSat, 0, 0, "", _salt());

        TokenReservationStub(token).setBridgedBalance(fromSat, 0);
        vm.prank(aliceIdentity);
        vm.expectRevert(ErrorsLib.ZeroValue.selector);
        mc.requestTransferValidation(fromSat, toSat, 0, 90, "", _salt());

        _assertNothingRecorded(fromSat);
    }

    /// @notice Two wallets of one identity: issued, recorded, but no module consulted.
    function test_requestTransferValidation_Success_WhenBothWalletsBelongToOneIdentity() public configured {
        address module = _bindAllowedAmountModule();
        RecordingModule(module).setAllowedAmount(5);
        _bind(toSat, aliceIdentity);

        vm.prank(aliceIdentity);
        bytes32 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());

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
        bytes32 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());

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
        bytes32 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());

        assertEq(mc.validationOf(id).amountMax, 30);
    }

    function test_requestTransferValidation_Success_WhenAModuleAnswersNoLimit() public configured {
        _bindAllowedAmountModule();

        vm.prank(aliceIdentity);
        bytes32 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());

        assertEq(mc.validationOf(id).amountMax, 90);
    }

    function test_requestTransferValidation_RevertWhen_AModuleEmptiesTheRange() public configured {
        address module = _bindAllowedAmountModule();
        RecordingModule(module).setAllowedAmount(5);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 10, 5));
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());
    }

    function test_requestTransferValidation_RevertWhen_AModuleRefuses() public configured {
        RecordingModule(_bindAllowedAmountModule()).setAllow(false);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 10, 0));
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());

        vm.prank(aliceIdentity);
        vm.expectRevert(ErrorsLib.ZeroValue.selector);
        mc.requestTransferValidation(fromSat, toSat, 0, 90, "", _salt());
    }

    function test_requestTransferValidation_RevertWhen_AModuleWritesInAllowedAmount() public configured {
        address module = address(new WritingRuleModule());
        mc.addModule(module);

        vm.prank(aliceIdentity);
        vm.expectRevert();
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());

        assertEq(WritingRuleModule(module).writes(), 0);
        _assertNothingRecorded(fromSat);
    }

    /// @notice A named spender is carried on the wire for the satellite to enforce, not resolved here: a
    ///         spender policy is about who moves the tokens, and the satellite is where that call happens.
    ///         The envelope must still parse, which is what keeps an unusable one out of the record.
    function test_requestTransferValidation_Success_WhenTheSpenderIsUnknownHere() public configured {
        bytes memory spender = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("spender"));
        _bind(spender, address(0));
        _bindAllowedAmountModule();

        vm.prank(aliceIdentity);
        bytes32 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, spender, _salt());

        assertEq(mc.validationOf(id).amountMax, 90);
    }

    function test_requestTransferValidation_Success_WhenTheSpenderResolves() public configured {
        bytes memory spender = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("spender"));
        _bind(spender, makeAddr("SpenderIdentity"));
        _bindAllowedAmountModule();

        bytes32 salt = _salt();
        vm.prank(aliceIdentity);
        assertEq(mc.requestTransferValidation(fromSat, toSat, 10, 90, spender, salt), _validationId(fromSat, salt));
    }

    /* ----- The reservation ----- */

    function test_requestTransferValidation_Success_WhenReservingThePendingAmounts() public configured {
        _track();

        vm.prank(aliceIdentity);
        bytes32 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());

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
        mc.requestTransferValidation(fromSat, toSat, 10, 30, "", _salt());
        mc.requestTransferValidation(fromSat, toOptimism, 10, 40, "", _salt());
        vm.stopPrank();

        assertEq(mc.pendingOutOf(aliceIdentity), 70);
        assertEq(mc.pendingInOf(bobIdentity), 70);
        assertEq(TokenReservationStub(token).reservedOf(fromSat), 70);
    }

    function test_requestTransferValidation_Success_WhenPendingOutOfTheWalletCapsTheNext() public configured {
        _track();

        vm.startPrank(aliceIdentity);
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());
        bytes32 second = mc.requestTransferValidation(fromSat, toSat, 5, 90, "", _salt());
        vm.stopPrank();

        assertEq(mc.validationOf(second).amountMax, BRIDGED_BALANCE - 90);
        assertEq(TokenReservationStub(token).reservedOf(fromSat), 100);

        vm.prank(aliceIdentity);
        vm.expectRevert(ErrorsLib.ZeroValue.selector);
        mc.requestTransferValidation(fromSat, toSat, 0, 90, "", _salt());
    }

    function test_requestTransferValidation_Success_WhenOneIdentityReservesNothing() public configured {
        _track();
        _bind(toSat, aliceIdentity);

        vm.prank(aliceIdentity);
        bytes32 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());

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
        bytes32 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
        assertEq(TokenReservationStub(token).reservedOf(fromSat), 90);
    }

    function test_requestTransferValidation_Success_WhenTwoValidationsRaceForOneCap() public configured {
        _track();
        address capped = _bindCappedModule(50);

        vm.startPrank(aliceIdentity);
        bytes32 first = mc.requestTransferValidation(fromSat, toSat, 10, 30, "", _salt());
        bytes32 second = mc.requestTransferValidation(fromSat, toOptimism, 10, 90, "", _salt());
        vm.stopPrank();

        assertEq(mc.validationOf(first).amountMax, 30);
        assertEq(mc.validationOf(second).amountMax, 20, "the second sees the first as executed at its maximum");
        assertEq(CappedRecipientModule(capped).capOf(address(mc)), 50);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 1, 0));
        mc.requestTransferValidation(fromSat, toSat, 1, 90, "", _salt());
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

    /// @notice The id is a function of the request alone: the same request lands under the same id whatever
    ///         was issued before it, and the same wallet cannot take a salt twice.
    function test_requestTransferValidation_Success_WhenTheIdDependsOnTheRequestAlone() public configured {
        bytes32 salt = _salt();
        bytes32 expected = _validationId(fromSat, salt);
        assertTrue(expected != _validationId(toSat, salt), "another wallet, another id");

        vm.startPrank(aliceIdentity);
        mc.requestTransferValidation(fromSat, toSat, 1, 5, "", _salt());
        mc.requestTransferValidation(fromSat, toSat, 1, 5, "", _salt());
        bytes32 id = mc.requestTransferValidation(fromSat, toSat, 10, 30, "", salt);
        vm.stopPrank();

        assertEq(id, expected, "independent of the number of earlier issuances");
    }

    function test_requestTransferValidation_RevertWhen_TheSaltWasAlreadyUsedForTheWallet() public configured {
        bytes32 salt = _salt();
        vm.startPrank(aliceIdentity);
        bytes32 id = mc.requestTransferValidation(fromSat, toSat, 10, 30, "", salt);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationAlreadyRequested.selector, id));
        mc.requestTransferValidation(fromSat, toSat, 10, 30, "", salt);
        // Other terms under the same salt are refused all the same: the id is taken.
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationAlreadyRequested.selector, id));
        mc.requestTransferValidation(fromSat, toOptimism, 1, 5, "", salt);
        vm.stopPrank();

        assertEq(mc.validationOf(id).amountMax, 30, "the first request stands");
    }

    function test_requestTransferValidation_Success_WhenIdsFollowTheSaltAndNeverRepeat() public configured {
        bytes32 saltA = _salt();
        bytes32 saltB = _salt();
        vm.startPrank(aliceIdentity);
        bytes32 first = mc.requestTransferValidation(fromSat, toSat, 10, 90, "", saltA);
        bytes32 second = mc.requestTransferValidation(fromSat, toSat, 10, 90, "", saltB);
        vm.stopPrank();

        assertEq(first, _validationId(fromSat, saltA));
        assertEq(second, _validationId(fromSat, saltB));
        assertTrue(first != second);
        assertTrue(mc.validationOf(first).hash != mc.validationOf(second).hash);
    }

    function test_requestTransferValidation_Success_WhenSnapshottingTheDeadlines() public configured {
        vm.warp(1_700_000_000);

        vm.prank(aliceIdentity);
        bytes32 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());

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
        bytes32 id = mc.requestTransferValidation(fromSat, toOptimism, 10, 90, "", _salt());

        ITransferValidation.Validation memory record = mc.validationOf(id);
        assertEq(record.releaseAt, 1_700_000_000 + VALIDITY_WINDOW + OPTIMISM_WINDOW);
        assertEq(record.fromChainKey, polygon);
        assertEq(record.toChainKey, optimism);
    }

    function test_requestTransferValidation_Success_WhenTheNativeRecipientKeepsTheReferenceKey() public configured {
        vm.prank(aliceIdentity);
        bytes32 id = mc.requestTransferValidation(fromSat, nativeBob, 10, 40, "", _salt());

        ITransferValidation.Validation memory record = mc.validationOf(id);
        assertEq(record.fromChainKey, polygon);
        assertEq(record.toChainKey, referenceChain);
        assertEq(record.fromKey, WalletKeyLib.canonicalKey(fromSat));
        assertEq(record.toKey, WalletKeyLib.canonicalKey(nativeBob));
        assertFalse(record.twoLegs);
    }

    function test_requestTransferValidation_Success_WhenRecordingTheWalletKeysAndTheLegCount() public configured {
        vm.startPrank(aliceIdentity);
        bytes32 sameChain = mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());
        bytes32 crossChain = mc.requestTransferValidation(fromSat, toOptimism, 10, 90, "", _salt());
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
        bytes32 salt = _salt();
        bytes32 id = _validationId(fromSat, salt);
        MessageTypesLib.ComplianceValidation memory expected =
            _expected(id, salt, fromSat, toSat, spender, 10, 90, POLYGON_WINDOW);

        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.TransferValidationIssued(
            id, fromSat, toSat, spender, 10, 90, expected.expiry, POLYGON_WINDOW, salt
        );
        vm.prank(aliceIdentity);
        mc.requestTransferValidation(fromSat, toSat, 10, 90, spender, salt);

        assertEq(mc.validationOf(id).hash, MessageTypesLib.hashValidation(expected));
    }

    function test_requestTransferValidation_Success_WhenDispatchingOneLegForASameChainMovement() public configured {
        vm.warp(1_700_000_000);
        bytes32 salt = _salt();
        bytes32 id = _validationId(fromSat, salt);
        MessageTypesLib.ComplianceValidation memory expected =
            _expected(id, salt, fromSat, toSat, "", 10, 90, POLYGON_WINDOW);

        vm.expectCall(token, abi.encodeCall(Token.dispatchComplianceValidation, (polygon, id, abi.encode(expected))), 1);
        vm.expectCall(token, abi.encodeWithSelector(Token.dispatchComplianceValidation.selector), 1);
        vm.prank(aliceIdentity);
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "", salt);
    }

    function test_requestTransferValidation_Success_WhenDispatchingTwoLegsForACrossChainMovement() public configured {
        vm.warp(1_700_000_000);
        bytes32 salt = _salt();
        bytes32 id = _validationId(fromSat, salt);
        MessageTypesLib.ComplianceValidation memory expected =
            _expected(id, salt, fromSat, toOptimism, "", 10, 90, OPTIMISM_WINDOW);
        bytes memory body = abi.encode(expected);

        vm.expectCall(token, abi.encodeCall(Token.dispatchComplianceValidation, (polygon, id, body)), 1);
        vm.expectCall(token, abi.encodeCall(Token.dispatchComplianceValidation, (optimism, id, body)), 1);
        vm.prank(aliceIdentity);
        mc.requestTransferValidation(fromSat, toOptimism, 10, 90, "", salt);
    }

    function test_requestTransferValidation_Success_WhenDispatchingToTheSatelliteSideOnly() public configured {
        bytes32 salt = _salt();
        bytes32 id = _validationId(fromSat, salt);
        vm.expectCall(token, abi.encodeWithSelector(Token.dispatchComplianceValidation.selector, polygon, id), 1);
        vm.expectCall(token, abi.encodeWithSelector(Token.dispatchComplianceValidation.selector), 1);
        vm.prank(aliceIdentity);
        mc.requestTransferValidation(fromSat, nativeBob, 10, 40, "", salt);
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
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "", _salt());

        _assertNothingRecorded(fromSat);
    }

    function _expected(
        bytes32 id,
        bytes32 salt,
        bytes memory from,
        bytes memory to,
        bytes memory spender,
        uint256 min,
        uint256 max,
        uint64 window
    ) private view returns (MessageTypesLib.ComplianceValidation memory) {
        return MessageTypesLib.ComplianceValidation({
            validationId: id,
            salt: salt,
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
