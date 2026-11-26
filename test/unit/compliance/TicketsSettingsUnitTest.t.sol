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

    // ==== .setWaitingTime Tests ====

    function test_setReconciliationWindow_Success_WhenCalledByManager() public {
        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.WaitingTimeSet(POLYGON, 30 minutes);
        mc.setWaitingTime(POLYGON, 30 minutes);

        assertEq(mc.waitingTimeOf(POLYGON), 30 minutes);
        assertEq(mc.waitingTimeOf(OPTIMISM), 0);
    }

    function test_setReconciliationWindow_RevertWhen_DurationIsZero() public {
        vm.expectRevert(ErrorsLib.ZeroDuration.selector);
        mc.setWaitingTime(POLYGON, 0);
    }

    function test_setReconciliationWindow_RevertWhen_CallerIsNotManager() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        mc.setWaitingTime(POLYGON, 30 minutes);
    }

    // ==== .blockAwayChain and .unblockAwayChain Tests ====

    function test_blockAwayChain_blocksOnlyThatChain() public {
        assertFalse(mc.isAwayChainBlocked(POLYGON));

        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.AwayChainBlockStarted(POLYGON);
        mc.blockAwayChain(POLYGON);

        assertTrue(mc.isAwayChainBlocked(POLYGON));
        assertFalse(mc.isAwayChainBlocked(OPTIMISM));
    }

    function test_unblockAwayChain_liftsTheBlock() public {
        mc.blockAwayChain(POLYGON);

        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.AwayChainUnblocked(POLYGON);
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

    /// @notice The bound token blocks the chain of a burn proof for a recall already settled, with no role.
    function test_blockAwayChain_succeeds_whenTheBoundTokenCalls() public {
        vm.prank(token);
        mc.blockAwayChain(POLYGON);

        assertTrue(mc.isAwayChainBlocked(POLYGON));
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
    function test_setDefaultValidityWindow_RevertWhen_CallerIsOnlyOwner() public {
        address owner = makeAddr("OnlyOwner");
        _grantOwnerRole(owner);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        mc.setDefaultValidityWindow(1 hours);
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

        mc.setDefaultValidityWindow(1 hours);

        assertEq(uint256(vm.load(address(mc), slot)), 1 hours);
    }

    function test_views_Success_WhenNothingWasIssued() public view {
        ITickets.Ticket memory record = mc.ticketOf(bytes32(uint256(1)));
        assertEq(record.askBlockHash, bytes32(0));
        assertEq(record.validUntil, 0);
        assertEq(record.waitingEndsAt, 0);
    }

}
