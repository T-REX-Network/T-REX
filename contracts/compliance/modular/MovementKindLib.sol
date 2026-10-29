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

// T-REX Smart Contracts
// The ERC-3643 token suite of the T-REX ecosystem.
//
// Copyright (C) 2026 Digital Asset Operational Services ISAC Ltd. ("T-REX Network")
//
// This file is part of the T-REX smart contract suite.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

pragma solidity 0.8.30;

/// @title MovementKindLib
/// @dev The values `TransferContext.kind` takes: what produced a movement.
///
///  A plain `uint8` rather than an enum, on purpose. Solidity range-checks an enum when it decodes calldata, so
///  a module compiled against six kinds would revert on a seventh and block every movement of that kind until
///  it is upgraded. With a number, a module that meets a kind it was not written for sees an unfamiliar value
///  and decides what to do with it. {IModule} makes that a MUST: a module never reverts on a kind it does not
///  know. What it does instead is the module's choice, and each tracker has to make it on purpose: a counter
///  of investor activity leaves an unknown kind out, a tracker that must see every change of ownership
///  records it.
///
///  Zero is never a kind. A context reports zero only when whoever built it forgot to set the field, which
///  a test then sees instead of a mislabeled movement: a forced transfer read as a plain transfer is the bug
///  this field exists to prevent.
library MovementKindLib {

    /// A wallet-to-wallet transfer the sender or an approved spender executed.
    uint8 internal constant TRANSFER = 1;
    /// An issuance of new tokens. `fromIdentity` and `fromWallet` are zero.
    uint8 internal constant MINT = 2;
    /// A destruction of tokens. `toIdentity` and `toWallet` are zero.
    uint8 internal constant BURN = 3;
    /// A transfer an agent forced. No rule was asked; trackers are told.
    uint8 internal constant FORCED_TRANSFER = 4;
    /// A lost wallet's balance moved to a new wallet of the same investor by an agent: recovery refuses an
    /// identity that does not own the lost wallet.
    uint8 internal constant RECOVERY = 5;
    /// A movement a satellite executes under a validation: the issuance of that validation while
    /// `isIssuance` is set, its settlement otherwise.
    uint8 internal constant CROSS_CHAIN = 6;
    /// A holder's native balance delegated out to a satellite wallet of the same identity. `fromWallet` and
    /// `toWallet` are both the native wallet: the position keeps its owner. Reported after the burn, like every
    /// movement, so the ledger follows a registry relink of the holder with the delegated amount counted back in.
    uint8 internal constant DELEGATION = 7;

}
