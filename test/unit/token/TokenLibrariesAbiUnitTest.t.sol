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

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { IToken } from "contracts/token/IToken.sol";

/// @dev Events and errors raised inside `TokenLedgerLib`, `TokenRecoveryLib` and `TokenGuardsLib` are
///  redeclared on `IToken` to stay in the token's ABI. This pins each redeclaration to the definition
///  the libraries actually use.
contract TokenLibrariesAbiUnitTest is Test {

    function test_events_MatchTheLibraryDefinitions() public pure {
        assertEq(IToken.ReservedForValidation.selector, EventsLib.ReservedForValidation.selector);
        assertEq(IToken.ReleasedFromValidation.selector, EventsLib.ReleasedFromValidation.selector);
        assertEq(IToken.ReturnedInTransit.selector, EventsLib.ReturnedInTransit.selector);
        assertEq(IToken.HeldInTransit.selector, EventsLib.HeldInTransit.selector);
        assertEq(IToken.BridgedTransfer.selector, EventsLib.BridgedTransfer.selector);
        assertEq(IToken.DelegatedOut.selector, EventsLib.DelegatedOut.selector);
        assertEq(IToken.RecallInstructed.selector, EventsLib.RecallInstructed.selector);
        assertEq(IToken.RecallSettled.selector, EventsLib.RecallSettled.selector);
        assertEq(IToken.BurnProofDuplicate.selector, EventsLib.BurnProofDuplicate.selector);
        assertEq(IToken.ReplayedBurnProof.selector, EventsLib.ReplayedBurnProof.selector);
        assertEq(IToken.InstructionResent.selector, EventsLib.InstructionResent.selector);
    }

    function test_errors_MatchTheLibraryDefinitions() public pure {
        assertEq(IToken.InsufficientBridgedBalance.selector, ErrorsLib.InsufficientBridgedBalance.selector);
        assertEq(IToken.NonCanonicalInteroperableAddress.selector, ErrorsLib.NonCanonicalInteroperableAddress.selector);
        assertEq(IToken.NotASatelliteWallet.selector, ErrorsLib.NotASatelliteWallet.selector);
        assertEq(IToken.NothingInTransit.selector, ErrorsLib.NothingInTransit.selector);
        assertEq(IToken.TransitAlreadyHeld.selector, ErrorsLib.TransitAlreadyHeld.selector);
        assertEq(IToken.TransitAmountMismatch.selector, ErrorsLib.TransitAmountMismatch.selector);
        assertEq(IToken.WalletsNotLinked.selector, ErrorsLib.WalletsNotLinked.selector);
        assertEq(IToken.RecallMismatch.selector, ErrorsLib.RecallMismatch.selector);
        assertEq(IToken.RecallAmountExceeded.selector, ErrorsLib.RecallAmountExceeded.selector);
        assertEq(IToken.RecallPending.selector, ErrorsLib.RecallPending.selector);
        assertEq(IToken.RecallNotPending.selector, ErrorsLib.RecallNotPending.selector);
        assertEq(IToken.DelegationMismatch.selector, ErrorsLib.DelegationMismatch.selector);
        assertEq(IToken.PeerChanged.selector, ErrorsLib.PeerChanged.selector);
        assertEq(IToken.UnknownResendKind.selector, ErrorsLib.UnknownResendKind.selector);
        assertEq(IToken.UnverifiedWallet.selector, ErrorsLib.UnverifiedWallet.selector);
        assertEq(IToken.NoTokenToRecover.selector, ErrorsLib.NoTokenToRecover.selector);
        assertEq(IToken.RecoveryNotPossible.selector, ErrorsLib.RecoveryNotPossible.selector);
        assertEq(IToken.SameWalletRecovery.selector, ErrorsLib.SameWalletRecovery.selector);
        assertEq(IToken.TokenCirculating.selector, ErrorsLib.TokenCirculating.selector);
        assertEq(IToken.InvalidIdentityRegistry.selector, ErrorsLib.InvalidIdentityRegistry.selector);
        assertEq(IToken.InvalidCompliance.selector, ErrorsLib.InvalidCompliance.selector);
        assertEq(IToken.ComplianceAlreadyBoundToToken.selector, ErrorsLib.ComplianceAlreadyBoundToToken.selector);
    }

}
