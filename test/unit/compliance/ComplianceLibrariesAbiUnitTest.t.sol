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

import { Test } from "@forge-std/Test.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IModularCompliance } from "contracts/compliance/modular/IModularCompliance.sol";
import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

/// @dev Events and errors raised inside `ModuleSetLib`, `TicketLib`, `ReceiptLib`, `SecondHalfLib` and `HoldLib` are
///  redeclared on the compliance's interfaces to stay in its ABI. This pins each redeclaration to the
///  definition the libraries actually use.
contract ComplianceLibrariesAbiUnitTest is Test {

    function test_events_MatchTheLibraryDefinitions() public pure {
        assertEq(IModularCompliance.ModuleInteraction.selector, EventsLib.ModuleInteraction.selector);
        assertEq(IModularCompliance.ModuleAdded.selector, EventsLib.ModuleAdded.selector);
        assertEq(IModularCompliance.ModuleTypesRecorded.selector, EventsLib.ModuleTypesRecorded.selector);
        assertEq(ITickets.TicketWritten.selector, EventsLib.TicketWritten.selector);
        assertEq(ITickets.ReceiptReceived.selector, EventsLib.ReceiptReceived.selector);
        assertEq(ITickets.ReceiptApplied.selector, EventsLib.ReceiptApplied.selector);
        assertEq(ITickets.ReceiptDuplicate.selector, EventsLib.ReceiptDuplicate.selector);
        assertEq(ITickets.TicketCancelled.selector, EventsLib.TicketCancelled.selector);
        assertEq(ITickets.ReceiptWaiting.selector, EventsLib.ReceiptWaiting.selector);
        assertEq(ITickets.WaitingReceiptApplied.selector, EventsLib.WaitingReceiptApplied.selector);
        assertEq(ITickets.WaitingReceiptRefused.selector, EventsLib.WaitingReceiptRefused.selector);
        assertEq(ITickets.AwayChainBlockStarted.selector, EventsLib.AwayChainBlockStarted.selector);
        assertEq(ITickets.AwayChainUnblocked.selector, EventsLib.AwayChainUnblocked.selector);
        assertEq(ITickets.ReceiptRefused.selector, EventsLib.ReceiptRefused.selector);
        assertEq(ITickets.ReceiptOnOlderTerms.selector, EventsLib.ReceiptOnOlderTerms.selector);
        assertEq(ITickets.MoveBreachedRule.selector, EventsLib.MoveBreachedRule.selector);
        assertEq(ITickets.TicketLimitsSet.selector, EventsLib.TicketLimitsSet.selector);
        assertEq(ITickets.ValidityWindowsSet.selector, EventsLib.ValidityWindowsSet.selector);
        assertEq(ITickets.WaitingTimeSet.selector, EventsLib.WaitingTimeSet.selector);
        assertEq(ITickets.MeasuredTimesSet.selector, EventsLib.MeasuredTimesSet.selector);
        assertEq(ITickets.AsksPausedSet.selector, EventsLib.AsksPausedSet.selector);
        assertEq(ITickets.AskLimitsSet.selector, EventsLib.AskLimitsSet.selector);
        assertEq(ITickets.AskLimitOfSet.selector, EventsLib.AskLimitOfSet.selector);
        assertEq(ITickets.ReceiptAsked.selector, EventsLib.ReceiptAsked.selector);
        assertEq(ITickets.TicketStillOpen.selector, EventsLib.TicketStillOpen.selector);
        assertEq(ITickets.SecondHalfSent.selector, EventsLib.SecondHalfSent.selector);
        assertEq(ITickets.SecondHalfNotSent.selector, EventsLib.SecondHalfNotSent.selector);
        assertEq(ITickets.NewHalfLimitReached.selector, EventsLib.NewHalfLimitReached.selector);
        assertEq(ITickets.ReceiptWithoutTicket.selector, EventsLib.ReceiptWithoutTicket.selector);
        assertEq(ITickets.ReceiptUnknown.selector, EventsLib.ReceiptUnknown.selector);
        assertEq(ITickets.HoldTaken.selector, EventsLib.HoldTaken.selector);
        assertEq(ITickets.HoldCancelled.selector, EventsLib.HoldCancelled.selector);
        assertEq(ITickets.CancelHoldShort.selector, EventsLib.CancelHoldShort.selector);
        assertEq(ITickets.ClosedByHand.selector, EventsLib.ClosedByHand.selector);
    }

    function test_errors_MatchTheLibraryDefinitions() public pure {
        assertEq(
            IModularCompliance.ComplianceNotSuitableForBindingToModule.selector,
            ErrorsLib.ComplianceNotSuitableForBindingToModule.selector
        );
        assertEq(IModularCompliance.MaxModulesReached.selector, ErrorsLib.MaxModulesReached.selector);
        assertEq(IModularCompliance.ModuleAlreadyBound.selector, ErrorsLib.ModuleAlreadyBound.selector);
        assertEq(IModularCompliance.ModuleHasNoType.selector, ErrorsLib.ModuleHasNoType.selector);
        assertEq(IModularCompliance.DuplicateModuleType.selector, ErrorsLib.DuplicateModuleType.selector);
        assertEq(IModularCompliance.ModuleNotBound.selector, ErrorsLib.ModuleNotBound.selector);
        assertEq(ITickets.InvalidRequestedRange.selector, ErrorsLib.InvalidRequestedRange.selector);
        assertEq(ITickets.NotACrossChainMove.selector, ErrorsLib.NotACrossChainMove.selector);
        assertEq(ITickets.FrozenWallet.selector, ErrorsLib.FrozenWallet.selector);
        assertEq(ITickets.SecondHalfNotOwed.selector, ErrorsLib.SecondHalfNotOwed.selector);
        assertEq(ITickets.NoNewHalfLeft.selector, ErrorsLib.NoNewHalfLeft.selector);
        assertEq(ITickets.NotEnoughGasForTheSecondHalf.selector, ErrorsLib.NotEnoughGasForTheSecondHalf.selector);
        assertEq(ITickets.ValidationBodyMismatch.selector, ErrorsLib.ValidationBodyMismatch.selector);
        assertEq(ITickets.UnverifiedWallet.selector, ErrorsLib.UnverifiedWallet.selector);
        assertEq(ITickets.NotAuthorizedForWallet.selector, ErrorsLib.NotAuthorizedForWallet.selector);
        assertEq(ITickets.EmptyValidationRange.selector, ErrorsLib.EmptyValidationRange.selector);
        assertEq(ITickets.ZeroValue.selector, ErrorsLib.ZeroValue.selector);
        assertEq(ITickets.ValidationSpenderRefused.selector, ErrorsLib.ValidationSpenderRefused.selector);
        assertEq(ITickets.TicketAlreadyWritten.selector, ErrorsLib.TicketAlreadyWritten.selector);
        assertEq(ITickets.NoWaitingReceipt.selector, ErrorsLib.NoWaitingReceipt.selector);
        assertEq(ITickets.AwayChainNotBlocked.selector, ErrorsLib.AwayChainNotBlocked.selector);
        assertEq(ITickets.AwayChainBlocked.selector, ErrorsLib.AwayChainBlocked.selector);
        assertEq(ITickets.HostileChangeNotOver.selector, ErrorsLib.HostileChangeNotOver.selector);
        assertEq(ITickets.InsufficientBridgedBalance.selector, ErrorsLib.InsufficientBridgedBalance.selector);
        assertEq(ITickets.ApplyWaitingReceiptFirst.selector, ErrorsLib.ApplyWaitingReceiptFirst.selector);
        assertEq(ITickets.TokenPaused.selector, ErrorsLib.TokenPaused.selector);
        assertEq(ITickets.TicketNotCancellable.selector, ErrorsLib.TicketNotCancellable.selector);
        assertEq(ITickets.CancelNotDue.selector, ErrorsLib.CancelNotDue.selector);
        assertEq(ITickets.NoAsksLeft.selector, ErrorsLib.NoAsksLeft.selector);
        assertEq(ITickets.SendNotDue.selector, ErrorsLib.SendNotDue.selector);
        assertEq(ITickets.WaitingTimeTooShort.selector, ErrorsLib.WaitingTimeTooShort.selector);
        assertEq(ITickets.ValidityWindowOutOfRange.selector, ErrorsLib.ValidityWindowOutOfRange.selector);
        assertEq(ITickets.AsksPaused.selector, ErrorsLib.AsksPaused.selector);
        assertEq(ITickets.AsksNotPaused.selector, ErrorsLib.AsksNotPaused.selector);
        assertEq(ITickets.AskLimitReached.selector, ErrorsLib.AskLimitReached.selector);
        assertEq(ITickets.TooManyOpenTickets.selector, ErrorsLib.TooManyOpenTickets.selector);
        assertEq(ITickets.BelowSmallestAmount.selector, ErrorsLib.BelowSmallestAmount.selector);
        assertEq(ITickets.RequestAboveBalance.selector, ErrorsLib.RequestAboveBalance.selector);
        assertEq(ITickets.ZeroDuration.selector, ErrorsLib.ZeroDuration.selector);
        assertEq(ITickets.ChainNotOpen.selector, ErrorsLib.ChainNotOpen.selector);
        assertEq(ITickets.UnknownTicket.selector, ErrorsLib.UnknownTicket.selector);
        assertEq(ITickets.PerTicketCapLoweredTooEarly.selector, ErrorsLib.PerTicketCapLoweredTooEarly.selector);
        assertEq(
            ITickets.NonCanonicalInteroperableAddress.selector, ErrorsLib.NonCanonicalInteroperableAddress.selector
        );
        assertEq(ITickets.WalletsNotLinked.selector, ErrorsLib.WalletsNotLinked.selector);
        assertEq(ITickets.BringHomeAlreadyOpen.selector, ErrorsLib.BringHomeAlreadyOpen.selector);
        assertEq(ITickets.WaitingTimeNotSet.selector, ErrorsLib.WaitingTimeNotSet.selector);
        assertEq(ITickets.NotASatelliteWallet.selector, ErrorsLib.NotASatelliteWallet.selector);
        assertEq(ITickets.LaterHoldStillCarries.selector, ErrorsLib.LaterHoldStillCarries.selector);
        assertEq(ITickets.HeldReceiptBreaksItsTerms.selector, ErrorsLib.HeldReceiptBreaksItsTerms.selector);
        assertEq(ITickets.AwayClockBeforeValidUntil.selector, ErrorsLib.AwayClockBeforeValidUntil.selector);
        assertEq(ITickets.ReceiptRouteNotClosed.selector, ErrorsLib.ReceiptRouteNotClosed.selector);
        assertEq(
            ITickets.InteroperableAddressEmptyReferenceAndAddress.selector,
            InteroperableAddress.InteroperableAddressEmptyReferenceAndAddress.selector
        );
        assertEq(ITickets.SafeCastOverflowedUintDowncast.selector, SafeCast.SafeCastOverflowedUintDowncast.selector);
    }

}
