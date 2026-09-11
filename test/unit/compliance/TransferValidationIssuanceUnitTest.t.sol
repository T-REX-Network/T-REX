// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ModularComplianceBaseUnitTest } from "./helpers/ModularComplianceBaseUnitTest.t.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { Token } from "contracts/token/Token.sol";
import { BoundsModule } from "test/integration/mocks/BoundsModule.sol";

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
    uint256 internal constant FREE_BALANCE = 50;

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
        vm.mockCall(token, abi.encodeWithSignature("freeBalanceOf(address)", alice), abi.encode(FREE_BALANCE));
        vm.mockCall(token, abi.encodeWithSignature("bridgedBalanceOf(bytes)", fromSat), abi.encode(BRIDGED_BALANCE));
        vm.mockCall(token, abi.encodeWithSelector(Token.dispatchComplianceValidation.selector), abi.encode(bytes32(0)));

        _bind(fromSat, aliceIdentity);
        _bind(nativeAlice, aliceIdentity);
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
        assertEq(mc.nextValidationId(), 1);
    }

    function test_requestTransferValidation_Success_WhenCalledByTheNativeHolder() public configured {
        vm.prank(alice);
        uint256 id = mc.requestTransferValidation(nativeAlice, toSat, 10, 40, "");

        assertEq(id, 1);
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

    function test_requestTransferValidation_RevertWhen_AnotherHolderCallsForANativeWallet() public configured {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAuthorizedForWallet.selector, bob, nativeAlice));
        mc.requestTransferValidation(nativeAlice, toSat, 10, 40, "");
    }

    // ==== preconditions Tests ====

    function test_requestTransferValidation_RevertWhen_RangeIsInverted() public configured {
        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidRequestedRange.selector, 20, 10));
        mc.requestTransferValidation(fromSat, toSat, 20, 10, "");
    }

    function test_requestTransferValidation_RevertWhen_BothWalletsAreNative() public configured {
        vm.prank(alice);
        vm.expectRevert(ErrorsLib.NoSatelliteLeg.selector);
        mc.requestTransferValidation(nativeAlice, nativeBob, 10, 40, "");
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
        mc.pauseValidationIssuance(polygon);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationIssuancePaused.selector, polygon));
        mc.requestTransferValidation(fromSat, toOptimism, 10, 90, "");
    }

    function test_requestTransferValidation_RevertWhen_ToChainIsPaused() public configured {
        mc.pauseValidationIssuance(optimism);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationIssuancePaused.selector, optimism));
        mc.requestTransferValidation(fromSat, toOptimism, 10, 90, "");
    }

    function test_requestTransferValidation_Success_AfterTheChainIsUnpaused() public configured {
        mc.pauseValidationIssuance(polygon);
        mc.unpauseValidationIssuance(polygon);

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

        ITransferValidation.ValidationRecord memory record = mc.validationOf(id);
        assertEq(record.amountMin, 90);
        assertEq(record.amountMax, BRIDGED_BALANCE);
    }

    function test_requestTransferValidation_Success_WhenCappingAtTheFreeBalance() public configured {
        vm.prank(alice);
        uint256 id = mc.requestTransferValidation(nativeAlice, toSat, 10, 200, "");

        assertEq(mc.validationOf(id).amountMax, FREE_BALANCE);
    }

    function test_requestTransferValidation_Success_WhenTheRequestIsInsideTheBalance() public configured {
        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(fromSat, toSat, 9, 11, "");

        ITransferValidation.ValidationRecord memory record = mc.validationOf(id);
        assertEq(record.amountMin, 9);
        assertEq(record.amountMax, 11);
    }

    function test_requestTransferValidation_RevertWhen_RequestedMinIsAboveTheBalance() public configured {
        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 150, BRIDGED_BALANCE));
        mc.requestTransferValidation(fromSat, toSat, 150, 200, "");

        assertEq(mc.nextValidationId(), 0);
    }

    function test_requestTransferValidation_Success_WhenTheClampAppliesLast() public configured {
        mc.setValidationClamp(60);

        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");

        assertEq(mc.validationOf(id).amountMax, 60);
    }

    function test_requestTransferValidation_RevertWhen_TheClampEmptiesTheRange() public configured {
        mc.setValidationClamp(5);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 10, 5));
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "");

        assertEq(mc.nextValidationId(), 0);
    }

    /// @notice Two wallets of one identity: issued, recorded, but no module consulted.
    function test_requestTransferValidation_Success_WhenBothWalletsBelongToOneIdentity() public configured {
        address bounds = _bindBoundsModule();
        mc.callModuleFunction(abi.encodeCall(BoundsModule.setFloor, (1000)), bounds);
        _bind(toSat, aliceIdentity);

        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");

        ITransferValidation.ValidationRecord memory record = mc.validationOf(id);
        assertEq(record.amountMin, 10);
        assertEq(record.amountMax, 90);
    }

    function test_requestTransferValidation_RevertWhen_AModuleEmptiesTheRange() public configured {
        address bounds = _bindBoundsModule();
        mc.callModuleFunction(abi.encodeCall(BoundsModule.setFloor, (1000)), bounds);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 1000, 90));
        mc.requestTransferValidation(fromSat, toSat, 10, 90, "");
    }

    // ==== record, event and dispatch Tests ====

    function test_requestTransferValidation_Success_WhenIdsIncreaseAndNeverRepeat() public configured {
        vm.startPrank(aliceIdentity);
        uint256 first = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");
        uint256 second = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");
        vm.stopPrank();

        assertEq(first, 1);
        assertEq(second, 2);
        assertEq(mc.nextValidationId(), 2);
        assertTrue(mc.validationOf(first).hash != mc.validationOf(second).hash);
    }

    function test_requestTransferValidation_Success_WhenSnapshottingTheDeadlines() public configured {
        vm.warp(1_700_000_000);

        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");

        ITransferValidation.ValidationRecord memory record = mc.validationOf(id);
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

        ITransferValidation.ValidationRecord memory record = mc.validationOf(id);
        assertEq(record.releaseAt, 1_700_000_000 + VALIDITY_WINDOW + OPTIMISM_WINDOW);
        assertEq(record.fromChainKey, polygon);
        assertEq(record.toChainKey, optimism);
    }

    function test_requestTransferValidation_Success_WhenTheNativeSideKeepsTheReferenceKey() public configured {
        vm.prank(alice);
        uint256 id = mc.requestTransferValidation(nativeAlice, toSat, 10, 40, "");

        ITransferValidation.ValidationRecord memory record = mc.validationOf(id);
        assertEq(record.fromChainKey, referenceChain);
        assertEq(record.toChainKey, polygon);
    }

    function test_requestTransferValidation_Success_WhenTheEventAndRecordMatchTheObject() public configured {
        vm.warp(1_700_000_000);
        bytes memory spender = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("spender"));
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
        vm.prank(alice);
        mc.requestTransferValidation(nativeAlice, toSat, 10, 40, "");
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

        assertEq(mc.nextValidationId(), 0);
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

    function _bindBoundsModule() private returns (address module) {
        module = address(new ModuleProxy(address(new BoundsModule()), abi.encodeCall(BoundsModule.initialize, ())));
        mc.addModule(module);
    }

    function _evmChainKey(uint256 chainId) private pure returns (bytes32) {
        (bytes2 chainType, bytes memory chainReference,) =
            InteroperableAddress.parseV1(InteroperableAddress.formatEvmV1(chainId));
        return MessageTypesLib.chainKey(chainType, chainReference);
    }

}
