// SPDX-License-Identifier: GPL-3.0
//
//                                             :+#####%%%%%%%%%%%%%%+
//                                         .-*@@@%+.:+%@@@@@%%#***%@@%=
//                                     :=*%@@@#=.      :#@@%       *@@@%=
//                       .-+*%@%*-.:+%@@@@@@+.     -*+:  .=#.       :%@@@%-
//                   :=*@@@@%%@@@@@@@@@%@@@-   .=#@@@%@%=             =@@@@#.
//             -=+#%@@%#*=:.  :%@@@@%.   -*@@#*@@@@@@@#=:-              *@@@@+
//            =@@%=:.     :=:   *@@@@@%#-   =%*%@@@@#+-.        =+       :%@@@%-
//           -@@%.     .+@@@     =+=-.         @@#-           +@@@%-       =@@@@%:
//          :@@@.    .+@@#%:                   :    .=*=-::.-%@@@+*@@=       +@@@@#.
//          %@@:    +@%%*                         =%@@@@@@@@@@@#.  .*@%-       +@@@@*.
//         #@@=                                .+@@@@%:=*@@@@@-      :%@%:      .*@@@@+
//        *@@*                                +@@@#-@@%-:%@@*          +@@#.      :%@@@@-
//       -@@%           .:-=++*##%%%@@@@@@@@@@@@*. :@+.@@@%:            .#@@+       =@@@@#:
//      .@@@*-+*#%%%@@@@@@@@@@@@@@@@%%#**@@%@@@.   *@=*@@#                :#@%=      .#@@@@#-
//      -%@@@@@@@@@@@@@@@*+==-:-@@@=    *@# .#@*-=*@@@@%=                 -%@@@*       =@@@@@%-
//         -+%@@@#.   %@%%=   -@@:+@: -@@*    *@@*-::                   -%@@%=.         .*@@@@@#
//            *@@@*  +@* *@@##@@-  #@*@@+    -@@=          .         :+@@@#:           .-+@@@%+-
//             +@@@%*@@:..=@@@@*   .@@@*   .#@#.       .=+-       .=%@@@*.         :+#@@@@*=:
//              =@@@@%@@@@@@@@@@@@@@@@@@@@@@%-      :+#*.       :*@@@%=.       .=#@@@@%+:
//               .%@@=                 .....    .=#@@+.       .#@@@*:       -*%@@@@%+.
//                 +@@#+===---:::...         .=%@@*-         +@@@+.      -*@@@@@%+.
//                  -@@@@@@@@@@@@@@@@@@@@@@%@@@@=          -@@@+      -#@@@@@#=.
//                    ..:::---===+++***###%%%@@@#-       .#@@+     -*@@@@@#=.
//                                           @@@@@@+.   +@@*.   .+@@@@@%=.
//                                          -@@@@@=   =@@%:   -#@@@@%+.
//                                          +@@@@@. =@@@=  .+@@@@@*:
//                                          #@@@@#:%@@#. :*@@@@#-
//                                          @@@@@%@@@= :#@@@@+.
//                                         :@@@@@@@#.:#@@@%-
//                                         +@@@@@@-.*@@@*:
//                                         #@@@@#.=@@@+.
//                                         @@@@+-%@%=
//                                        :@@@#%@%=
//                                        +@@@@%-
//                                        :#%%=
//

pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ModularComplianceBaseUnitTest } from "./helpers/ModularComplianceBaseUnitTest.t.sol";
import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

/// @dev The settings of the validation layer: the COMPLIANCE_MANAGER's windows and the pauser's block of an away
///      chain, with their events and their guards.
contract TicketsSettingsUnitTest is ModularComplianceBaseUnitTest {

    bytes32 internal constant POLYGON = keccak256(abi.encodePacked(bytes2(0x0000), hex"89"));
    bytes32 internal constant OPTIMISM = keccak256(abi.encodePacked(bytes2(0x0000), hex"0a"));

    // ==== .setValidityWindows Tests ====

    function test_setValidityWindows_Success_WhenCalledByManager() public {
        assertEq(mc.validityWindows().onTicketRoute, 0);

        vm.expectEmit(false, false, false, true, address(mc));
        emit EventsLib.ValidityWindowsSet(15 minutes, 25 minutes);
        mc.setValidityWindows(15 minutes, 25 minutes);

        assertEq(mc.validityWindows().onTicketRoute, 15 minutes);
        assertEq(mc.validityWindows().onReceiptRoute, 25 minutes);
    }

    /// @notice A window of zero is not above the floor, which is zero while nothing was measured.
    function test_setValidityWindows_reverts_when_aWindowIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidityWindowOutOfRange.selector, 0, 0, 1 days));
        mc.setValidityWindows(0, 25 minutes);
    }

    function test_setValidityWindows_reverts_when_theCallerIsNotManager() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        mc.setValidityWindows(15 minutes, 25 minutes);
    }

    // ==== .setWaitingTime Tests ====

    function test_setWaitingTime_Success_WhenCalledByManager() public {
        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.WaitingTimeSet(POLYGON, 95 minutes);
        mc.setWaitingTime(POLYGON, 95 minutes);

        assertEq(mc.waitingTimeOf(POLYGON), 95 minutes);
        assertEq(mc.waitingTimeOf(OPTIMISM), 0);
    }

    /// @notice A waiting time is at least one hour, so zero is below the floor.
    function test_setWaitingTime_reverts_when_theDurationIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WaitingTimeTooShort.selector, POLYGON, 0, 1 hours - 1));
        mc.setWaitingTime(POLYGON, 0);
    }

    function test_setWaitingTime_reverts_when_theCallerIsNotManager() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        mc.setWaitingTime(POLYGON, 95 minutes);
    }

    // ==== .blockAwayChain and .unblockAwayChain Tests ====

    function test_blockAwayChain_blocksOnlyThatChain() public {
        assertFalse(mc.isAwayChainBlocked(POLYGON));

        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.AwayChainBlockSet(POLYGON, true);
        mc.blockAwayChain(POLYGON);

        assertTrue(mc.isAwayChainBlocked(POLYGON));
        assertFalse(mc.isAwayChainBlocked(OPTIMISM));
    }

    function test_unblockAwayChain_liftsTheBlock() public {
        mc.blockAwayChain(POLYGON);

        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.AwayChainBlockSet(POLYGON, false);
        mc.unblockAwayChain(POLYGON);

        assertFalse(mc.isAwayChainBlocked(POLYGON));
    }

    /// @notice Blocking a blocked chain, or unblocking an open one, changes nothing and emits nothing, so a pauser can
    ///         block without first checking whether a bad receipt already did.
    function test_blockAwayChain_changesNothing_whenTheStateIsAlreadyTheOneAsked() public {
        mc.blockAwayChain(POLYGON);

        vm.recordLogs();
        mc.blockAwayChain(POLYGON);
        assertEq(vm.getRecordedLogs().length, 0, "no event on a no-op");
        assertTrue(mc.isAwayChainBlocked(POLYGON));

        mc.unblockAwayChain(POLYGON);
        vm.recordLogs();
        mc.unblockAwayChain(POLYGON);
        assertEq(vm.getRecordedLogs().length, 0, "no event on a no-op");
        assertFalse(mc.isAwayChainBlocked(POLYGON));
    }

    function test_blockAwayChain_reverts_when_theCallerHasNoRole() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        mc.blockAwayChain(POLYGON);
    }

    /// @notice The bound token has no door to the block any more: only the pauser blocks by hand.
    function test_blockAwayChain_reverts_when_theBoundTokenCalls() public {
        vm.prank(token);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, token));
        mc.blockAwayChain(POLYGON);

        assertFalse(mc.isAwayChainBlocked(POLYGON));
    }

    /// @notice Only the pauser lifts a block, whoever set it: a bad receipt blocks from inside `receiveReceipt`, and
    ///         the lift is never automatic.
    function test_unblockAwayChain_reverts_when_theCallerHasNoRole() public {
        mc.blockAwayChain(POLYGON);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        mc.unblockAwayChain(POLYGON);
        assertTrue(mc.isAwayChainBlocked(POLYGON), "the chain stays blocked until the pauser acts");
    }

    /// @notice The bound token blocks, it never unblocks.
    function test_unblockAwayChain_reverts_when_theBoundTokenCalls() public {
        mc.blockAwayChain(POLYGON);

        vm.prank(token);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, token));
        mc.unblockAwayChain(POLYGON);
    }

    /// @notice OWNER alone does not reach the manager surface: the roles are distinct.
    function test_setValidityWindows_reverts_when_theCallerIsOnlyOwner() public {
        address owner = makeAddr("OnlyOwner");
        _grantOwnerRole(owner);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        mc.setValidityWindows(15 minutes, 25 minutes);
    }

    // ==== .supportsInterface and storage Tests ====

    function test_supportsInterface_Success_WhenQueriedForITransferValidation() public view {
        assertTrue(mc.supportsInterface(type(ITickets).interfaceId));
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

        mc.setValidityWindows(15 minutes, 25 minutes);

        assertEq(uint256(vm.load(address(mc), slot)), 15 minutes | (25 minutes << 64));
    }

    function test_views_Success_WhenNothingWasIssued() public view {
        ITickets.Ticket memory record = mc.ticketOf(bytes32(uint256(1)));
        assertEq(record.askBlockHash, bytes32(0));
        assertEq(record.validUntil, 0);
    }

}
