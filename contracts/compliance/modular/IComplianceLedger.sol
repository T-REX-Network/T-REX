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

/// @title IComplianceLedger
/// @dev The four numbers the compliance keeps, and the only thing a module reads from it.
///
/// The token knows balances per wallet. One investor holds several wallets, on this chain and on satellites,
/// and every rule about how the asset is distributed asks the same two questions about the investor, not the
/// wallet: how much does this identity own in total, and how much is already promised to or from it by
/// validations that have not settled yet. The compliance is the contract that sees every movement and issues
/// every validation, so it keeps those numbers itself, once, instead of each module rebuilding them.
///
/// Nothing here is written from outside: the compliance updates these from the hooks the token already calls
/// and from its own issuance, settlement and discard paths.
///
/// The positions are exact: `sum(positions) == totalSupply`. The token's identity registry admits no wallet
/// without an active identity, even with its eligibility checks disabled, so every token lands on a wallet with
/// an owner. A wallet keeps resolving after its investor revokes it, and a token that circulates may not change its
/// registry or its compliance. Registry writes never relink a wallet, but the owner can still change who a wallet
/// resolves to by swapping the registry's storage or unbinding a registry from it. The ledger keeps up on its own:
/// it remembers which identity it credited each native wallet to (`ownerOf`), and the next movement through a
/// wallet whose owner changed moves its balance to the new owner before applying the movement. A wallet the
/// registry no longer names keeps its remembered owner.
interface IComplianceLedger {

    /// @dev What `identity` owns in total: free, frozen and bridged, over every wallet linked to it, revoked
    ///  wallets included. Moving tokens between two wallets of one identity does not change it.
    /// @param identity the ONCHAINID to look up
    function positionOf(address identity) external view returns (uint256);

    /// @dev Sum of `amountMax` over the validations issued toward `identity` that have not settled or been
    ///  discarded. What a cap on acquisitions must count on top of the position.
    /// @param identity the ONCHAINID to look up
    function pendingInOf(address identity) external view returns (uint256);

    /// @dev Sum of `amountMax` over the validations issued out of `identity` that have not settled or been
    ///  discarded. What a floor on holdings must subtract from the position.
    /// @param identity the ONCHAINID to look up
    function pendingOutOf(address identity) external view returns (uint256);

    /// @dev The identity a native wallet's tokens are counted under: the one it was last credited to. An empty
    ///  wallet follows the registry on its next movement; a funded one keeps this owner until the registry names
    ///  it again. Zero for a wallet the ledger has never credited.
    function ownerOf(address wallet) external view returns (address);

}
