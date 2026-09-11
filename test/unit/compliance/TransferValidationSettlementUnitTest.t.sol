// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ModularComplianceBaseUnitTest } from "./helpers/ModularComplianceBaseUnitTest.t.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { IToken } from "contracts/token/IToken.sol";
import { Token } from "contracts/token/Token.sol";
import { BoundsModule } from "test/integration/mocks/BoundsModule.sol";
import { SlotsOnlyModule } from "test/integration/mocks/SlotsModule.sol";

/// @dev The settlement classification on a mocked token: every gate that reverts, the branch that settles, and
///      the two emergencies that halt without writing.
contract TransferValidationSettlementUnitTest is ModularComplianceBaseUnitTest {

    uint256 internal constant POLYGON = 137;
    uint256 internal constant OPTIMISM = 10;
    uint64 internal constant VALIDITY_WINDOW = 1 hours;
    uint64 internal constant POLYGON_WINDOW = 30 minutes;
    uint64 internal constant OPTIMISM_WINDOW = 45 minutes;
    uint256 internal constant ISSUED_AT = 1_700_000_000;
    uint256 internal constant BRIDGED_BALANCE = 100;
    uint256 internal constant FREE_BALANCE = 50;

    bytes32 internal polygon = _evmChainKey(POLYGON);
    bytes32 internal optimism = _evmChainKey(OPTIMISM);
    address internal alice = makeAddr("alice");
    address internal aliceIdentity = makeAddr("AliceIdentity");
    address internal bobIdentity = makeAddr("BobIdentity");
    bytes internal fromSat;
    bytes internal toSat;
    bytes internal toOptimism;
    bytes internal nativeAlice;
    bytes internal carolSat;

    function setUp() public override {
        super.setUp();
        fromSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("aliceOnPolygon"));
        toSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("bobOnPolygon"));
        toOptimism = InteroperableAddress.formatEvmV1(OPTIMISM, makeAddr("bobOnOptimism"));
        nativeAlice = InteroperableAddress.formatEvmV1(block.chainid, alice);
        carolSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("carolOnPolygon"));

        mc.setDefaultValidityWindow(VALIDITY_WINDOW);
        mc.setReconciliationWindow(polygon, POLYGON_WINDOW);
        mc.setReconciliationWindow(optimism, OPTIMISM_WINDOW);

        vm.mockCall(token, abi.encodeWithSignature("identityRegistry()"), abi.encode(registry));
        vm.mockCall(token, abi.encodeWithSignature("freeBalanceOf(address)", alice), abi.encode(FREE_BALANCE));
        vm.mockCall(token, abi.encodeWithSignature("bridgedBalanceOf(bytes)", fromSat), abi.encode(BRIDGED_BALANCE));
        vm.mockCall(token, abi.encodeWithSelector(Token.dispatchComplianceValidation.selector), abi.encode(bytes32(0)));
        vm.mockCall(token, abi.encodeWithSelector(IToken.settleValidation.selector), "");
        _bind(fromSat, aliceIdentity);
        _bind(nativeAlice, aliceIdentity);
        _bind(toSat, bobIdentity);
        _bind(toOptimism, bobIdentity);

        vm.warp(ISSUED_AT);
    }

    // ==== caller Tests ====

    function test_handleSettlement_RevertWhen_CallerIsNotTheBoundToken() public {
        uint256 id = _issue();

        vm.prank(stranger);
        vm.expectRevert(ErrorsLib.AddressNotATokenBoundToComplianceContract.selector);
        mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));
    }

    // ==== gate Tests ====

    function test_handleSettlement_RevertWhen_TokenIsAnotherAsset() public {
        uint256 id = _issue();
        address other = makeAddr("OtherAsset");
        MessageTypesLib.SettlementNotification memory leg = _leg(id, fromSat, toSat, 50);
        leg.token = other;

        vm.prank(token);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementTokenMismatch.selector, other));
        mc.handleSettlement(polygon, leg);
    }

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

    function test_handleSettlement_RevertWhen_TheValidationIsDiscarded() public {
        uint256 id = _issue();
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(keeperAccount);
        mc.discardExpiredValidations(ids);

        vm.prank(token);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationNotSettleable.selector, id));
        mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));
    }

    // ==== settlement Tests ====

    function test_handleSettlement_Success_WhenAPendingValidationSettles() public {
        address slots = _bindSlotsModule();
        address bounds = _bindBoundsModule();
        uint256 id = _issue();

        vm.expectCall(slots, abi.encodeCall(IModule.commitSlot, (id, 50)), 1);
        vm.expectCall(bounds, abi.encodeWithSelector(IModule.commitSlot.selector), 0);
        vm.expectCall(token, abi.encodeCall(IToken.settleValidation, (fromSat, toSat, 50, id)), 1);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.SettlementNotified(polygon, id, fromSat, toSat, 50);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ValidationSettled(id, polygon, 50);
        vm.prank(token);
        bool halt = mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertFalse(halt);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        ITransferValidation.ValidationState memory state = mc.stateOf(id);
        assertTrue(state.fromLegConsumed);
        assertTrue(state.toLegConsumed);
        assertEq(state.executedAmount, 50);
        assertEq(SlotsOnlyModule(slots).lastExecutedAmount(), 50);
    }

    function test_handleSettlement_Success_WhenTheAmountIsOnABound() public {
        uint256 first = _issue();
        uint256 second = _issue();

        vm.startPrank(token);
        mc.handleSettlement(polygon, _leg(first, fromSat, toSat, 10));
        mc.handleSettlement(polygon, _leg(second, fromSat, toSat, 90));
        vm.stopPrank();

        assertEq(mc.stateOf(first).executedAmount, 10);
        assertEq(mc.stateOf(second).executedAmount, 90);
    }

    function test_handleSettlement_Success_WhenTheNativeSideIsTheSender() public {
        vm.prank(alice);
        uint256 id = mc.requestTransferValidation(nativeAlice, toSat, 10, 40, "");

        vm.expectCall(token, abi.encodeCall(IToken.settleValidation, (nativeAlice, toSat, 40, id)), 1);
        vm.prank(token);
        bool halt = mc.handleSettlement(polygon, _leg(id, nativeAlice, toSat, 40));

        assertFalse(halt);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
    }

    function test_handleSettlement_Success_WhenPastTheReleaseDeadlineBeforeAnyDiscard() public {
        uint256 id = _issue();
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Expired));

        vm.prank(token);
        bool halt = mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertFalse(halt);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertFalse(mc.isIssuancePaused(polygon));
    }

    // ==== emergency Tests ====

    function test_handleSettlement_Success_WhenAConsumedLegIsReplayed() public {
        address slots = _bindSlotsModule();
        uint256 id = _issue();
        vm.prank(token);
        mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        vm.expectCall(slots, abi.encodeWithSelector(IModule.commitSlot.selector), 0);
        vm.expectCall(token, abi.encodeWithSelector(IToken.settleValidation.selector), 0);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ReplayedSettlement(id, polygon);
        vm.prank(token);
        bool halt = mc.handleSettlement(polygon, _leg(id, fromSat, toSat, 50));

        assertTrue(halt);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(mc.stateOf(id).executedAmount, 50);
        assertEq(SlotsOnlyModule(slots).commitCalls(), 1);
    }

    function test_handleSettlement_Success_WhenTheIdWasNeverIssued() public {
        uint256 id = _issue();

        vm.expectCall(token, abi.encodeWithSelector(IToken.settleValidation.selector), 0);
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.ReplayedSettlement(id + 1, polygon);
        vm.prank(token);
        bool halt = mc.handleSettlement(polygon, _leg(id + 1, fromSat, toSat, 50));

        assertTrue(halt);
        assertEq(mc.stateOf(id + 1).executedAmount, 0);
        assertFalse(mc.stateOf(id + 1).fromLegConsumed);

        vm.prank(token);
        assertTrue(mc.handleSettlement(polygon, _leg(0, fromSat, toSat, 50)));
    }

    function _issue() private returns (uint256 id) {
        vm.prank(aliceIdentity);
        id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");
    }

    function _leg(uint256 id, bytes memory from, bytes memory to, uint256 amount)
        private
        view
        returns (MessageTypesLib.SettlementNotification memory)
    {
        return MessageTypesLib.SettlementNotification({
            validationId: id, token: token, from: from, to: to, amount: amount
        });
    }

    function _assertUntouched(uint256 id) private view {
        ITransferValidation.ValidationState memory state = mc.stateOf(id);
        assertEq(uint8(state.status), uint8(ITransferValidation.ValidationStatus.Pending));
        assertFalse(state.fromLegConsumed);
        assertFalse(state.toLegConsumed);
        assertEq(state.executedAmount, 0);
    }

    function _bind(bytes memory wallet, address identity) private {
        vm.mockCall(registry, abi.encodeWithSignature("resolveIdentity(bytes)", wallet), abi.encode(identity));
        vm.mockCall(
            registry, abi.encodeWithSignature("isWalletVerified(bytes)", wallet), abi.encode(identity != address(0))
        );
    }

    function _bindSlotsModule() private returns (address module) {
        module =
            address(new ModuleProxy(address(new SlotsOnlyModule()), abi.encodeCall(SlotsOnlyModule.initialize, ())));
        mc.addModule(module);
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
