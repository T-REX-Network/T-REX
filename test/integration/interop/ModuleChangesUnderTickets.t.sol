// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { AsyncApprovalModule } from "contracts/compliance/modular/modules/AsyncApprovalModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { CappedRecipientModule, RecordingModule } from "test/integration/mocks/CapabilityModules.sol";

/// @dev The modules change under a reserved ticket like any setting: only the unbind of the compliance waits for the
///      tickets. Whether a ticket waits for an approver is written at its ask, so an approval module is bound,
///      removed or filed again only while asks are paused for the whole token, and a ticket already written keeps
///      what was written for it.
contract ModuleChangesUnderTicketsTest is InteropSuiteTest {

    uint256 internal constant ALICE_AWAY_BALANCE = 1000;
    uint256 internal constant CAP = 500;

    bytes internal aliceSat;
    bytes internal bobSat;
    CappedRecipientModule internal capRule;
    AsyncApprovalModule internal approvalModule;

    function setUp() public override {
        super.setUp();
        _openEvmChain(token, POLYGON, address(_newReceiptBridge(POLYGON)));
        aliceSat =
            _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), ALICE_AWAY_BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        capRule = CappedRecipientModule(
            address(
                new ModuleProxy(address(new CappedRecipientModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        vm.prank(deployer);
        boundCompliance.addModule(address(capRule));
        approvalModule = AsyncApprovalModule(
            address(
                new ModuleProxy(
                    address(new AsyncApprovalModule()),
                    abi.encodeCall(AsyncApprovalModule.initialize, (address(suiteManager)))
                )
            )
        );

        vm.prank(agent);
        token.unpause();
    }

    /* ----- A change while a ticket is reserved ----- */

    /// @notice One open ticket, asked with no approval module: an approval module binds while asks are paused, and
    ///         the ticket stays one that never waited for approval, as written at its ask.
    function test_addModule_bindsAnApprovalModule_whileATicketIsReserved() public {
        bytes32 ticketId = _askOneTicket();
        assertFalse(boundCompliance.ticketOf(ticketId).waitedForApproval);
        vm.startPrank(deployer);
        boundCompliance.setAsksPaused(bytes32(0), true);

        boundCompliance.addModule(address(approvalModule));
        vm.stopPrank();

        assertTrue(boundCompliance.isModuleBound(address(approvalModule)));
        assertFalse(boundCompliance.ticketOf(ticketId).waitedForApproval, "as written at the ask");
    }

    function test_removeModule_removes_whileATicketIsReserved() public {
        _askOneTicket();

        vm.prank(deployer);
        boundCompliance.removeModule(address(capRule));

        assertFalse(boundCompliance.isModuleBound(address(capRule)));
    }

    function test_addAndSetModule_binds_whileATicketIsReserved() public {
        _askOneTicket();
        CappedRecipientModule another = CappedRecipientModule(
            address(
                new ModuleProxy(address(new CappedRecipientModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        bytes[] memory settings = new bytes[](1);
        settings[0] = abi.encodeCall(CappedRecipientModule.setCap, (CAP));

        vm.prank(deployer);
        boundCompliance.addAndSetModule(address(another), settings);

        assertTrue(boundCompliance.isModuleBound(address(another)));
    }

    function test_callModuleFunction_changesASetting_whileATicketIsReserved() public {
        _askOneTicket();

        vm.prank(deployer);
        boundCompliance.callModuleFunction(abi.encodeCall(CappedRecipientModule.setCap, (CAP)), address(capRule));
    }

    function test_resyncModuleTypes_files_whileATicketIsReserved() public {
        _askOneTicket();

        vm.prank(deployer);
        boundCompliance.resyncModuleTypes(address(capRule));

        assertTrue(boundCompliance.isModuleBound(address(capRule)));
    }

    /// @notice The forced removal stays the named repair for a module that reverts on every receipt.
    function test_forceRemoveModule_succeeds_when_ticketsAreStillReserved() public {
        bytes32 ticketId = _askOneTicket();

        vm.prank(deployer);
        boundCompliance.forceRemoveModule(address(capRule));

        assertFalse(boundCompliance.isModuleBound(address(capRule)));
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Open));
    }

    /* ----- An approval module only while asks are paused ----- */

    /// @notice With nothing reserved, an approval module still binds only while asks are paused, so no ask is taken
    ///         under the rules of neither.
    function test_addModule_reverts_when_anApprovalModuleIsBoundWhileAsksAreNotPaused() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.AsksNotPaused.selector);
        boundCompliance.addModule(address(approvalModule));

        vm.startPrank(deployer);
        boundCompliance.setAsksPaused(bytes32(0), true);
        boundCompliance.addModule(address(approvalModule));
        vm.stopPrank();
        assertTrue(boundCompliance.isModuleBound(address(approvalModule)));
    }

    function test_removeModule_reverts_when_anApprovalModuleIsRemovedWhileAsksAreNotPaused() public {
        _bindTheApprovalModule();

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.AsksNotPaused.selector);
        boundCompliance.removeModule(address(approvalModule));

        vm.startPrank(deployer);
        boundCompliance.setAsksPaused(bytes32(0), true);
        boundCompliance.removeModule(address(approvalModule));
        vm.stopPrank();
        assertFalse(boundCompliance.isModuleBound(address(approvalModule)));
    }

    function test_forceRemoveModule_reverts_when_anApprovalModuleIsRemovedWhileAsksAreNotPaused() public {
        _bindTheApprovalModule();

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.AsksNotPaused.selector);
        boundCompliance.forceRemoveModule(address(approvalModule));

        vm.startPrank(deployer);
        boundCompliance.setAsksPaused(bytes32(0), true);
        boundCompliance.forceRemoveModule(address(approvalModule));
        vm.stopPrank();
        assertFalse(boundCompliance.isModuleBound(address(approvalModule)));
    }

    function test_resyncModuleTypes_reverts_when_anApprovalModuleIsFiledAgainWhileAsksAreNotPaused() public {
        _bindTheApprovalModule();

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.AsksNotPaused.selector);
        boundCompliance.resyncModuleTypes(address(approvalModule));

        vm.startPrank(deployer);
        boundCompliance.setAsksPaused(bytes32(0), true);
        boundCompliance.resyncModuleTypes(address(approvalModule));
        vm.stopPrank();
        assertTrue(boundCompliance.isModuleBound(address(approvalModule)));
    }

    /* ----- Helpers ----- */

    function _askOneTicket() private returns (bytes32) {
        return _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 100);
    }

    function _bindTheApprovalModule() private {
        vm.startPrank(deployer);
        boundCompliance.setAsksPaused(bytes32(0), true);
        boundCompliance.addModule(address(approvalModule));
        boundCompliance.setAsksPaused(bytes32(0), false);
        vm.stopPrank();
    }

}
