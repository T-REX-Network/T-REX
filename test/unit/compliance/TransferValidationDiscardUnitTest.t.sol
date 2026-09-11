// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ModularComplianceBaseUnitTest } from "./helpers/ModularComplianceBaseUnitTest.t.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { Token } from "contracts/token/Token.sol";
import { BoundsModule } from "test/integration/mocks/BoundsModule.sol";
import { SlotsOnlyModule } from "test/integration/mocks/SlotsModule.sol";

/// @dev The lifecycle views and the keeper's discard on a mocked token and registry: what `statusOf` derives over
///      time, every refusal of a discard, and which modules a release reaches.
contract TransferValidationDiscardUnitTest is ModularComplianceBaseUnitTest {

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
    bytes internal fromSat;
    bytes internal toSat;
    bytes internal toOptimism;

    function setUp() public override {
        super.setUp();
        fromSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("aliceOnPolygon"));
        toSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("bobOnPolygon"));
        toOptimism = InteroperableAddress.formatEvmV1(OPTIMISM, makeAddr("bobOnOptimism"));

        mc.setDefaultValidityWindow(VALIDITY_WINDOW);
        mc.setReconciliationWindow(polygon, POLYGON_WINDOW);
        mc.setReconciliationWindow(optimism, OPTIMISM_WINDOW);

        vm.mockCall(token, abi.encodeWithSignature("identityRegistry()"), abi.encode(registry));
        vm.mockCall(token, abi.encodeWithSignature("bridgedBalanceOf(bytes)", fromSat), abi.encode(BRIDGED_BALANCE));
        vm.mockCall(token, abi.encodeWithSelector(Token.dispatchComplianceValidation.selector), abi.encode(bytes32(0)));
        _bind(fromSat, aliceIdentity);
        _bind(toSat, bobIdentity);
        _bind(toOptimism, bobIdentity);

        vm.warp(ISSUED_AT);
    }

    // ==== .statusOf Tests ====

    function test_statusOf_Success_WhenFreshlyIssued() public {
        uint256 id = _issue();

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
        ITransferValidation.ValidationState memory state = mc.stateOf(id);
        assertEq(uint8(state.status), uint8(ITransferValidation.ValidationStatus.Pending));
        assertFalse(state.fromLegConsumed);
        assertFalse(state.toLegConsumed);
        assertEq(state.executedAmount, 0);
        assertEq(state.legWallet.length, 0);
    }

    function test_statusOf_Success_WhenPastExpiryButNotPastReleaseAt() public {
        uint256 id = _issue();

        vm.warp(ISSUED_AT + VALIDITY_WINDOW + 1);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));

        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
    }

    function test_statusOf_Success_WhenPastReleaseAtItDerivesExpired() public {
        uint256 id = _issue();

        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Expired));
        assertEq(uint8(mc.stateOf(id).status), uint8(ITransferValidation.ValidationStatus.Pending));
    }

    function test_statusOf_Success_WhenBurnConfirmedNeverDerivesExpired() public {
        uint256 id = _issueCrossChainWithBurnLeg();

        vm.warp(ISSUED_AT + 10 * VALIDITY_WINDOW);

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.BurnConfirmed));
    }

    function test_statusOf_RevertWhen_IdWasNeverIssued() public {
        uint256 id = _issue();

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownValidation.selector, 0));
        mc.statusOf(0);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownValidation.selector, id + 1));
        mc.statusOf(id + 1);
    }

    function test_stateOf_Success_WhenIdWasNeverIssued() public view {
        ITransferValidation.ValidationState memory state = mc.stateOf(42);

        assertEq(uint8(state.status), 0);
        assertEq(state.executedAmount, 0);
    }

    // ==== .discardExpiredValidations Tests ====

    function test_discardExpiredValidations_Success_WhenExpired() public {
        address slots = _bindSlotsModule();
        address bounds = _bindBoundsModule();
        uint256 id = _issue();
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);

        vm.expectCall(slots, abi.encodeCall(IModule.releaseSlot, (id)), 1);
        vm.expectCall(bounds, abi.encodeWithSelector(IModule.releaseSlot.selector), 0);
        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.ValidationDiscarded(id);
        vm.prank(keeperAccount);
        mc.discardExpiredValidations(_ids(id));

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Discarded));
        assertEq(SlotsOnlyModule(slots).releaseCalls(), 1);
    }

    function test_discardExpiredValidations_Success_WhenBatchingSeveralIds() public {
        uint256 first = _issue();
        uint256 second = _issue();
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);

        uint256[] memory ids = new uint256[](2);
        ids[0] = first;
        ids[1] = second;
        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.ValidationDiscarded(first);
        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.ValidationDiscarded(second);
        vm.prank(keeperAccount);
        mc.discardExpiredValidations(ids);

        assertEq(uint8(mc.statusOf(first)), uint8(ITransferValidation.ValidationStatus.Discarded));
        assertEq(uint8(mc.statusOf(second)), uint8(ITransferValidation.ValidationStatus.Discarded));
    }

    function test_discardExpiredValidations_RevertWhen_CallerIsNotTheKeeper() public {
        uint256 id = _issue();
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);

        vm.prank(agentAccount);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agentAccount));
        mc.discardExpiredValidations(_ids(id));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        mc.discardExpiredValidations(_ids(id));

        // The manager holds the policy, not the garbage collection.
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        mc.discardExpiredValidations(_ids(id));
    }

    function test_discardExpiredValidations_RevertWhen_IdWasNeverIssued() public {
        vm.prank(keeperAccount);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownValidation.selector, 7));
        mc.discardExpiredValidations(_ids(7));
    }

    function test_discardExpiredValidations_RevertWhen_NotYetReleasable() public {
        uint256 id = _issue();
        uint64 releaseAt = uint64(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW);

        vm.warp(releaseAt);
        vm.prank(keeperAccount);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationNotReleasable.selector, id, releaseAt));
        mc.discardExpiredValidations(_ids(id));

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
    }

    function test_discardExpiredValidations_RevertWhen_AlreadyDiscarded() public {
        uint256 id = _issue();
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        vm.prank(keeperAccount);
        mc.discardExpiredValidations(_ids(id));

        vm.prank(keeperAccount);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotDiscardable.selector, id, uint8(ITransferValidation.ValidationStatus.Discarded)
            )
        );
        mc.discardExpiredValidations(_ids(id));
    }

    function test_discardExpiredValidations_RevertWhen_BurnConfirmedWhateverTheClock() public {
        uint256 id = _issueCrossChainWithBurnLeg();
        vm.warp(ISSUED_AT + 10 * VALIDITY_WINDOW);

        vm.prank(keeperAccount);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotDiscardable.selector,
                id,
                uint8(ITransferValidation.ValidationStatus.BurnConfirmed)
            )
        );
        mc.discardExpiredValidations(_ids(id));
    }

    function test_discardExpiredValidations_RevertWhen_OneIdOfTheBatchIsRefused() public {
        address slots = _bindSlotsModule();
        uint256 expired = _issue();
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        uint256 pending = _issue();
        uint64 pendingReleaseAt = uint64(block.timestamp + VALIDITY_WINDOW + POLYGON_WINDOW);

        uint256[] memory ids = new uint256[](2);
        ids[0] = expired;
        ids[1] = pending;
        vm.prank(keeperAccount);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationNotReleasable.selector, pending, pendingReleaseAt));
        mc.discardExpiredValidations(ids);

        assertEq(uint8(mc.statusOf(expired)), uint8(ITransferValidation.ValidationStatus.Expired));
        assertEq(SlotsOnlyModule(slots).releaseCalls(), 0);
    }

    function _issue() private returns (uint256 id) {
        vm.prank(aliceIdentity);
        id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");
    }

    /// @dev A cross-chain validation whose burn leg landed: the real `BurnConfirmed`.
    function _issueCrossChainWithBurnLeg() private returns (uint256 id) {
        vm.prank(aliceIdentity);
        id = mc.requestTransferValidation(fromSat, toOptimism, 10, 90, "");
        vm.prank(token);
        mc.handleSettlement(
            polygon,
            MessageTypesLib.SettlementNotification({
                validationId: id, token: token, from: fromSat, to: "", amount: 50
            })
        );
    }

    function _ids(uint256 id) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
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
