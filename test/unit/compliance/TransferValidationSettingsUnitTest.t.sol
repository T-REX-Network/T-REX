// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ModularComplianceBaseUnitTest } from "./helpers/ModularComplianceBaseUnitTest.t.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

/// @dev The COMPLIANCE_MANAGER surface of the validation layer: the five setters, their events and their
///      guards, plus the late-reconciliation hook that pauses a chain on its own.
contract TransferValidationSettingsUnitTest is ModularComplianceBaseUnitTest {

    bytes32 internal constant POLYGON = keccak256(abi.encodePacked(bytes2(0x0000), hex"89"));
    bytes32 internal constant OPTIMISM = keccak256(abi.encodePacked(bytes2(0x0000), hex"0a"));

    // ==== .setDefaultValidityWindow Tests ====

    function test_setDefaultValidityWindow_Success_WhenCalledByManager() public {
        assertEq(mc.defaultValidityWindow(), 0);

        vm.expectEmit(false, false, false, true, address(mc));
        emit EventsLib.DefaultValidityWindowSet(1 hours);
        mc.setDefaultValidityWindow(1 hours);

        assertEq(mc.defaultValidityWindow(), 1 hours);
    }

    function test_setDefaultValidityWindow_RevertWhen_DurationIsZero() public {
        vm.expectRevert(ErrorsLib.ZeroDuration.selector);
        mc.setDefaultValidityWindow(0);
    }

    function test_setDefaultValidityWindow_RevertWhen_CallerIsNotManager() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        mc.setDefaultValidityWindow(1 hours);
    }

    // ==== .setReconciliationWindow Tests ====

    function test_setReconciliationWindow_Success_WhenCalledByManager() public {
        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.ReconciliationWindowSet(POLYGON, 30 minutes);
        mc.setReconciliationWindow(POLYGON, 30 minutes);

        assertEq(mc.reconciliationWindowOf(POLYGON), 30 minutes);
        assertEq(mc.reconciliationWindowOf(OPTIMISM), 0);
    }

    function test_setReconciliationWindow_RevertWhen_DurationIsZero() public {
        vm.expectRevert(ErrorsLib.ZeroDuration.selector);
        mc.setReconciliationWindow(POLYGON, 0);
    }

    function test_setReconciliationWindow_RevertWhen_CallerIsNotManager() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        mc.setReconciliationWindow(POLYGON, 30 minutes);
    }

    // ==== .setValidationClamp Tests ====

    function test_setValidationClamp_Success_WhenCalledByManager() public {
        vm.expectEmit(false, false, false, true, address(mc));
        emit EventsLib.ValidationClampSet(1000);
        mc.setValidationClamp(1000);
        assertEq(mc.validationClamp(), 1000);

        vm.expectEmit(false, false, false, true, address(mc));
        emit EventsLib.ValidationClampSet(0);
        mc.setValidationClamp(0);
        assertEq(mc.validationClamp(), 0);
    }

    function test_setValidationClamp_RevertWhen_CallerIsNotManager() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        mc.setValidationClamp(1000);
    }

    // ==== .pauseValidationIssuance / .unpauseValidationIssuance Tests ====

    function test_pauseValidationIssuance_Success_WhenChainIsOpen() public {
        assertFalse(mc.isIssuancePaused(POLYGON));

        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.ValidationIssuancePaused(POLYGON);
        mc.pauseValidationIssuance(POLYGON);

        assertTrue(mc.isIssuancePaused(POLYGON));
        assertFalse(mc.isIssuancePaused(OPTIMISM));
    }

    function test_unpauseValidationIssuance_Success_WhenChainIsPaused() public {
        mc.pauseValidationIssuance(POLYGON);

        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.ValidationIssuanceUnpaused(POLYGON);
        mc.unpauseValidationIssuance(POLYGON);

        assertFalse(mc.isIssuancePaused(POLYGON));
    }

    function test_pauseValidationIssuance_RevertWhen_ChainIsAlreadyPaused() public {
        mc.pauseValidationIssuance(POLYGON);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationIssuancePaused.selector, POLYGON));
        mc.pauseValidationIssuance(POLYGON);
    }

    function test_unpauseValidationIssuance_RevertWhen_ChainIsNotPaused() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationIssuanceNotPaused.selector, POLYGON));
        mc.unpauseValidationIssuance(POLYGON);
    }

    function test_pauseValidationIssuance_RevertWhen_CallerIsNotManager() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        mc.pauseValidationIssuance(POLYGON);
    }

    function test_unpauseValidationIssuance_RevertWhen_CallerIsNotManager() public {
        mc.pauseValidationIssuance(POLYGON);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        mc.unpauseValidationIssuance(POLYGON);
    }

    /// @notice OWNER alone does not reach the manager surface: the roles are distinct.
    function test_setDefaultValidityWindow_RevertWhen_CallerIsOnlyOwner() public {
        address owner = makeAddr("OnlyOwner");
        _grantOwnerRole(owner);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        mc.setDefaultValidityWindow(1 hours);
    }

    // ==== ._onLateReconciliation Tests ====

    function test_onLateReconciliation_Success_WhenChainIsOpen() public {
        vm.expectEmit(true, true, false, true, address(mc));
        emit EventsLib.LateReconciliation(7, POLYGON);
        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.ValidationIssuancePaused(POLYGON);
        mc.exposed_onLateReconciliation(7, POLYGON);

        assertTrue(mc.isIssuancePaused(POLYGON));
    }

    function test_onLateReconciliation_Success_WhenChainIsAlreadyPaused() public {
        mc.pauseValidationIssuance(POLYGON);

        vm.recordLogs();
        mc.exposed_onLateReconciliation(7, POLYGON);

        assertEq(vm.getRecordedLogs().length, 1, "only the warning is emitted");
        assertTrue(mc.isIssuancePaused(POLYGON));
    }

    /// @notice Only the manager lifts an automatic pause, and issuance stays closed until then.
    function test_unpauseValidationIssuance_Success_AfterALateReconciliation() public {
        mc.exposed_onLateReconciliation(7, POLYGON);

        mc.unpauseValidationIssuance(POLYGON);

        assertFalse(mc.isIssuancePaused(POLYGON));
    }

    // ==== .supportsInterface and storage Tests ====

    function test_supportsInterface_Success_WhenQueriedForITransferValidation() public view {
        assertTrue(mc.supportsInterface(type(ITransferValidation).interfaceId));
    }

    /// @notice The namespace sits where its derivation says, apart from the compliance's own storage.
    function test_storageLocation_Success_WhenDerivedFromTheNamespace() public {
        bytes32 slot = keccak256(abi.encode(uint256(keccak256("ERC3643.storage.TransferValidation")) - 1))
            & ~bytes32(uint256(0xff));

        mc.setDefaultValidityWindow(1 hours);

        assertEq(uint256(vm.load(address(mc), slot)), 1 hours);
    }

    function test_views_Success_WhenNothingWasIssued() public view {
        assertEq(mc.nextValidationId(), 0);
        ITransferValidation.ValidationRecord memory record = mc.validationOf(1);
        assertEq(record.hash, bytes32(0));
        assertEq(record.expiry, 0);
        assertEq(record.releaseAt, 0);
    }

}
