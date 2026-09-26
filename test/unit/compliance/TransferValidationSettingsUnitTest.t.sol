// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ModularComplianceBaseUnitTest } from "./helpers/ModularComplianceBaseUnitTest.t.sol";
import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
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

    // ==== .setIssuancePaused Tests ====

    function test_setIssuancePaused_Success_WhenPausingAnOpenChain() public {
        assertFalse(mc.isIssuancePaused(POLYGON));

        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.ValidationIssuancePaused(POLYGON);
        mc.setIssuancePaused(POLYGON, true);

        assertTrue(mc.isIssuancePaused(POLYGON));
        assertFalse(mc.isIssuancePaused(OPTIMISM));
    }

    function test_setIssuancePaused_Success_WhenResumingAPausedChain() public {
        mc.setIssuancePaused(POLYGON, true);

        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.ValidationIssuanceUnpaused(POLYGON);
        mc.setIssuancePaused(POLYGON, false);

        assertFalse(mc.isIssuancePaused(POLYGON));
    }

    /// @notice Setting the state a chain already has changes nothing and emits nothing, so a keeper can
    ///         pause without first checking whether someone else already did.
    function test_setIssuancePaused_Success_WhenTheStateIsAlreadyTheOneAsked() public {
        mc.setIssuancePaused(POLYGON, true);

        vm.recordLogs();
        mc.setIssuancePaused(POLYGON, true);
        assertEq(vm.getRecordedLogs().length, 0, "no event on a no-op");
        assertTrue(mc.isIssuancePaused(POLYGON));

        mc.setIssuancePaused(POLYGON, false);
        vm.recordLogs();
        mc.setIssuancePaused(POLYGON, false);
        assertEq(vm.getRecordedLogs().length, 0, "no event on a no-op");
        assertFalse(mc.isIssuancePaused(POLYGON));
    }

    function test_setIssuancePaused_RevertWhen_PauserIsNotManager() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        mc.setIssuancePaused(POLYGON, true);
    }

    function test_setIssuancePaused_RevertWhen_ResumerIsNotManager() public {
        mc.setIssuancePaused(POLYGON, true);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        mc.setIssuancePaused(POLYGON, false);
    }

    /// @notice OWNER alone does not reach the manager surface: the roles are distinct.
    function test_setDefaultValidityWindow_RevertWhen_CallerIsOnlyOwner() public {
        address owner = makeAddr("OnlyOwner");
        _grantOwnerRole(owner);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        mc.setDefaultValidityWindow(1 hours);
    }

    // ==== automatic pause Tests ====

    /// @notice Only the manager lifts a pause, whoever set it. A late settlement that breached a rule closes
    ///         the chain from inside `handleSettlement`; `LateReconciliation.t.sol` covers that path end to
    ///         end, and this pins that the lift is a manager action and not automatic.
    function test_setIssuancePaused_Success_WhenTheManagerLiftsAnAutomaticPause() public {
        mc.setIssuancePaused(POLYGON, true);
        assertTrue(mc.isIssuancePaused(POLYGON));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        mc.setIssuancePaused(POLYGON, false);
        assertTrue(mc.isIssuancePaused(POLYGON), "issuance stays closed until the manager acts");

        mc.setIssuancePaused(POLYGON, false);
        assertFalse(mc.isIssuancePaused(POLYGON));
    }

    // ==== .supportsInterface and storage Tests ====

    function test_supportsInterface_Success_WhenQueriedForITransferValidation() public view {
        assertTrue(mc.supportsInterface(type(ITransferValidation).interfaceId));
    }

    /// @notice The compliance advertises the ledger, which is how a module finds the four numbers it reads.
    ///         A rule resolves them through this id, so an implementation that stopped answering it would
    ///         leave every rule reading a contract that cannot answer.
    function test_supportsInterface_Success_WhenQueriedForIComplianceLedger() public view {
        assertTrue(mc.supportsInterface(type(IComplianceLedger).interfaceId));
    }

    /// @notice The namespace sits where its derivation says, apart from the compliance's own storage.
    function test_storageLocation_Success_WhenDerivedFromTheNamespace() public {
        bytes32 slot = keccak256(abi.encode(uint256(keccak256("erc3643.storage.TransferValidation")) - 1))
            & ~bytes32(uint256(0xff));

        mc.setDefaultValidityWindow(1 hours);

        assertEq(uint256(vm.load(address(mc), slot)), 1 hours);
    }

    function test_views_Success_WhenNothingWasIssued() public view {
        assertEq(mc.lastValidationId(), 0);
        ITransferValidation.Validation memory record = mc.validationOf(1);
        assertEq(record.hash, bytes32(0));
        assertEq(record.expiry, 0);
        assertEq(record.releaseAt, 0);
    }

}
