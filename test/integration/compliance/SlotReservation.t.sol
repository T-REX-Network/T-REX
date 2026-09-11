// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { ModuleCapabilitiesLib as Caps } from "contracts/libraries/ModuleCapabilitiesLib.sol";
import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { TransferValidationHarness } from "test/integration/helpers/TransferValidationHarness.sol";
import { CheckTransferOnlyModule, RecordingModule } from "test/integration/mocks/CapabilityModules.sol";
import { SlotsModule } from "test/integration/mocks/SlotsModule.sol";

/// @dev Why reservations exist: two validations issued against one cap cannot jointly breach it, because the
///      first one is counted at its worst case until it settles or is discarded. The compliance is the harness,
///      so commit and release can be driven before the settlement and discard paths land.
contract SlotReservationTest is InteropSuiteTest {

    uint256 internal constant CAP = 100;
    uint256 internal constant BALANCE = 1000;

    bytes internal aliceSat;
    bytes internal bobSat;
    SlotsModule internal slots;
    TransferValidationHarness internal harness;

    function setUp() public override {
        super.setUp();
        harness = TransferValidationHarness(address(boundCompliance));
        _openEvmChain(token, POLYGON, address(_newTrustedGateway(POLYGON)));
        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        slots = SlotsModule(
            address(new ModuleProxy(address(new SlotsModule()), abi.encodeCall(SlotsModule.initialize, ())))
        );
        vm.startPrank(deployer);
        boundCompliance.addModule(address(slots));
        boundCompliance.callModuleFunction(abi.encodeCall(SlotsModule.setCap, (CAP)), address(slots));
        vm.stopPrank();
    }

    /// @dev The suite's compliance is the harness, so the internal hooks are reachable.
    function _deployImplementations() internal override {
        super._deployImplementations();
        modularComplianceImplementation = ModularCompliance(address(new TransferValidationHarness()));
    }

    // ==== reservation Tests ====

    /// @notice The first validation reserves its worst case on the recipient.
    function test_requestTransferValidation_Success_WhenTheFirstValidationReservesItsMaximum() public {
        vm.expectCall(address(slots), abi.encodeCall(IModule.reserveSlot, (1, aliceSat, bobSat, 60)), 1);
        uint256 id = _issue(10, 60);

        assertEq(id, 1);
        assertEq(_max(id), 60);
        assertEq(slots.heldOf(address(boundCompliance), bobSat), 60);
        assertEq(slots.reserveCalls(), 1);
        assertEq(slots.lastReservedId(), 1);
        assertEq(slots.lastReservedAmount(), 60);
    }

    /// @notice The second validation is narrowed by the first one's reservation and reserves the remainder.
    function test_requestTransferValidation_Success_WhenTheSecondValidationIsNarrowedByTheFirst() public {
        _issue(10, 60);

        vm.expectCall(address(slots), abi.encodeCall(IModule.reserveSlot, (2, aliceSat, bobSat, 40)), 1);
        uint256 id = _issue(10, 60);

        assertEq(_max(id), 40);
        assertEq(slots.heldOf(address(boundCompliance), bobSat), CAP);
        assertEq(slots.reserveCalls(), 2);
    }

    /// @notice With the cap fully reserved, a third validation is refused before any write.
    function test_requestTransferValidation_RevertWhen_TheCapIsFullyReserved() public {
        _issue(10, 60);
        _issue(10, 60);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 1, 0));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 1, 1, "");

        assertEq(slots.reserveCalls(), 2);
        assertEq(boundCompliance.nextValidationId(), 2);
    }

    /// @notice A static module bound beside the counter receives no slot call at any point.
    function test_requestTransferValidation_Success_WhenAStaticModuleIsUntouched() public {
        CheckTransferOnlyModule checker = CheckTransferOnlyModule(
            address(
                new ModuleProxy(address(new CheckTransferOnlyModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        vm.prank(deployer);
        boundCompliance.addModule(address(checker));

        vm.expectCall(address(checker), abi.encodeWithSelector(IModule.reserveSlot.selector), 0);
        vm.expectCall(address(checker), abi.encodeWithSelector(IModule.commitSlot.selector), 0);
        vm.expectCall(address(checker), abi.encodeWithSelector(IModule.releaseSlot.selector), 0);
        uint256 id = _issue(10, 60);
        harness.exposed_commitSlots(id, 50);
        harness.exposed_releaseSlots(id);

        assertEq(checker.totalHookCalls(), 0);
        assertEq(boundCompliance.getModulesByCapability(Caps.SLOTS).length, 1);
    }

    // ==== commit and release Tests ====

    /// @notice A commit at the exact amount lowers the counter by the unexecuted remainder.
    function test_commitSlots_Success_WhenCommittingBelowTheReservation() public {
        uint256 first = _issue(10, 60);
        _issue(10, 60);

        vm.expectCall(address(slots), abi.encodeCall(IModule.commitSlot, (first, 50)), 1);
        harness.exposed_commitSlots(first, 50);

        assertEq(slots.heldOf(address(boundCompliance), bobSat), 90);
        assertEq(slots.commitCalls(), 1);
        assertEq(slots.lastCommittedId(), first);
        assertEq(slots.lastCommittedAmount(), 50);
        assertEq(slots.reservationOf(address(boundCompliance), first).amount, 0);
    }

    /// @notice A release restores the counter entirely and frees the room for a new validation.
    function test_releaseSlots_Success_WhenReleasingARservation() public {
        _issue(10, 60);
        uint256 second = _issue(10, 60);

        vm.expectCall(address(slots), abi.encodeCall(IModule.releaseSlot, (second)), 1);
        harness.exposed_releaseSlots(second);

        assertEq(slots.heldOf(address(boundCompliance), bobSat), 60);
        assertEq(slots.releaseCalls(), 1);
        assertEq(slots.lastReleasedId(), second);

        assertEq(_max(_issue(10, 60)), 40);
    }

    /// @notice A commit for an id the module never reserved applies the delta anyway.
    function test_commitSlots_Success_WhenThereIsNoLiveReservation() public {
        harness.exposed_commitSlots(42, 30);

        assertEq(slots.commitCalls(), 1);
        assertEq(slots.lastCommittedId(), 42);
        assertEq(slots.lastCommittedAmount(), 30);
    }

    /// @notice A release for an id the module never reserved is a no-op that still counts.
    function test_releaseSlots_Success_WhenThereIsNoLiveReservation() public {
        harness.exposed_releaseSlots(42);

        assertEq(slots.releaseCalls(), 1);
        assertEq(slots.heldOf(address(boundCompliance), bobSat), 0);
    }

    function _issue(uint256 requestedMin, uint256 requestedMax) private returns (uint256) {
        return _requestValidation(address(aliceIdentity), aliceSat, bobSat, requestedMin, requestedMax);
    }

    function _max(uint256 id) private view returns (uint256) {
        ITransferValidation.ValidationRecord memory record = boundCompliance.validationOf(id);
        return record.amountMax;
    }

}
