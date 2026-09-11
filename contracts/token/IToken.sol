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

/**
 *     NOTICE
 *
 *     The T-REX software is licensed under a proprietary license or the GPL v.3.
 *     If you choose to receive it under the GPL v.3 license, the following applies:
 *     T-REX is a suite of smart contracts implementing the ERC-3643 standard and
 *     developed by Tokeny to manage and transfer financial assets on EVM blockchains
 *
 *     Copyright (C) 2025, Tokeny sàrl.
 *
 *     This program is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     This program is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

pragma solidity 0.8.30;

import { IERC3643 } from "../ERC-3643/IERC3643.sol";

/// @title IToken
/// @notice The T-REX token surface beyond ERC-3643: the ledger views the standard does not define.
///  A position has three buckets. Free and frozen are native and `balanceOf` is their sum, plain ERC-20.
///  Bridged is the part delegated to satellites, per ERC-7930 wallet, outside `balanceOf`; `totalSupply` counts
///  all three.
interface IToken is IERC3643 {

    /// @notice Returns the part of a wallet's balance that is movable on this chain: `balanceOf` minus frozen.
    /// @param wallet the wallet to read
    function freeBalanceOf(address wallet) external view returns (uint256);

    /// @notice Returns the position delegated to a satellite wallet.
    /// @dev A non-canonical envelope reverts rather than reading a key no transition ever wrote.
    /// @param wallet the ERC-7930 envelope of the satellite wallet
    function bridgedBalanceOf(bytes calldata wallet) external view returns (uint256);

    /// @notice Returns the sum of every bridged position: the part of `totalSupply` active on satellites.
    function totalBridged() external view returns (uint256);

    /// @notice Applies a settled validation to the ledger, once, by the shape of its wallets: a native `from` is a
    ///  delegation-out of the holder's free balance to `to`, a native `to` is a recall of `from` onto the holder,
    ///  and two satellite wallets are a bridged transfer under `validationId`.
    /// @dev Callable by the bound compliance only, which classified the settlement against the validation it
    ///  issued; reverts with `OnlyBoundCompliance` otherwise. A native `from` whose free balance no longer covers
    ///  `amount` reverts with `ERC20InsufficientBalance` and leaves the settlement retryable: nothing locks the
    ///  native side at issuance. Bypasses `_update`, like every ledger transition.
    /// @param from the ERC-7930 envelope of the sender
    /// @param to the ERC-7930 envelope of the recipient
    /// @param amount the exact amount the satellite executed
    /// @param validationId the validation the settlement consumed
    function settleValidation(bytes calldata from, bytes calldata to, uint256 amount, uint256 validationId) external;

}
