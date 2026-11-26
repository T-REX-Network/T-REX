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
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

/// @dev Events and errors raised inside `ModuleSetLib`, `TransferValidationLib` and `TransferSettlementLib` are
///  redeclared on the compliance's interfaces to stay in its ABI. This pins each redeclaration to the
///  definition the libraries actually use.
contract ComplianceLibrariesAbiUnitTest is Test {

    function test_events_MatchTheLibraryDefinitions() public pure {
        assertEq(IModularCompliance.ModuleInteraction.selector, EventsLib.ModuleInteraction.selector);
        assertEq(IModularCompliance.ModuleAdded.selector, EventsLib.ModuleAdded.selector);
        assertEq(IModularCompliance.ModuleTypesRecorded.selector, EventsLib.ModuleTypesRecorded.selector);
        assertEq(ITransferValidation.TransferValidationIssued.selector, EventsLib.TransferValidationIssued.selector);
        assertEq(ITransferValidation.SettlementNotified.selector, EventsLib.SettlementNotified.selector);
        assertEq(ITransferValidation.ValidationLegConfirmed.selector, EventsLib.ValidationLegConfirmed.selector);
        assertEq(ITransferValidation.ValidationSettled.selector, EventsLib.ValidationSettled.selector);
        assertEq(ITransferValidation.LateReconciliation.selector, EventsLib.LateReconciliation.selector);
        assertEq(ITransferValidation.ReplayedSettlement.selector, EventsLib.ReplayedSettlement.selector);
        assertEq(ITransferValidation.ValidationDiscarded.selector, EventsLib.ValidationDiscarded.selector);
        assertEq(ITransferValidation.ValidationResolved.selector, EventsLib.ValidationResolved.selector);
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
        assertEq(ITransferValidation.InvalidRequestedRange.selector, ErrorsLib.InvalidRequestedRange.selector);
        assertEq(ITransferValidation.SenderNotOnSatellite.selector, ErrorsLib.SenderNotOnSatellite.selector);
        assertEq(ITransferValidation.UnverifiedWallet.selector, ErrorsLib.UnverifiedWallet.selector);
        assertEq(ITransferValidation.NotAuthorizedForWallet.selector, ErrorsLib.NotAuthorizedForWallet.selector);
        assertEq(ITransferValidation.EmptyValidationRange.selector, ErrorsLib.EmptyValidationRange.selector);
        assertEq(ITransferValidation.ZeroValue.selector, ErrorsLib.ZeroValue.selector);
        assertEq(ITransferValidation.ValidationSpenderRefused.selector, ErrorsLib.ValidationSpenderRefused.selector);
        assertEq(ITransferValidation.SettlementLegMismatch.selector, ErrorsLib.SettlementLegMismatch.selector);
        assertEq(ITransferValidation.SettlementOutOfBounds.selector, ErrorsLib.SettlementOutOfBounds.selector);
        assertEq(ITransferValidation.SettlementAmountMismatch.selector, ErrorsLib.SettlementAmountMismatch.selector);
        assertEq(ITransferValidation.ValidationNotDiscardable.selector, ErrorsLib.ValidationNotDiscardable.selector);
        assertEq(ITransferValidation.ValidationNotReleasable.selector, ErrorsLib.ValidationNotReleasable.selector);
        assertEq(
            ITransferValidation.ValidationNotPubliclyDiscardable.selector,
            ErrorsLib.ValidationNotPubliclyDiscardable.selector
        );
        assertEq(ITransferValidation.ValidationNotStuck.selector, ErrorsLib.ValidationNotStuck.selector);
        assertEq(ITransferValidation.ValidationNotYetResolvable.selector, ErrorsLib.ValidationNotYetResolvable.selector);
        assertEq(
            ITransferValidation.NonCanonicalInteroperableAddress.selector,
            ErrorsLib.NonCanonicalInteroperableAddress.selector
        );
        assertEq(
            ITransferValidation.InteroperableAddressEmptyReferenceAndAddress.selector,
            InteroperableAddress.InteroperableAddressEmptyReferenceAndAddress.selector
        );
        assertEq(
            ITransferValidation.SafeCastOverflowedUintDowncast.selector,
            SafeCast.SafeCastOverflowedUintDowncast.selector
        );
    }

}
