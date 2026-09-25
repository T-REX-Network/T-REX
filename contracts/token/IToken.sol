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
///  all three. Inside the bridged bucket, an amount a satellite burned for a cross-chain validation whose mint
///  leg has not landed is held in transit against that validation: no wallet holds it, its sender still owns it.
interface IToken is IERC3643 {

    /// @notice Returns the part of a wallet's balance that is movable on this chain: `balanceOf` minus frozen.
    /// @param wallet the wallet to read
    function freeBalanceOf(address wallet) external view returns (uint256);

    /// @notice Returns the position delegated to a satellite wallet.
    /// @dev A non-canonical envelope reverts rather than reading a key no transition ever wrote.
    /// @param wallet the ERC-7930 envelope of the satellite wallet
    function bridgedBalanceOf(bytes calldata wallet) external view returns (uint256);

    /// @notice Returns the sum of every bridged position, the in-transit holds included: the part of
    ///  `totalSupply` active on satellites. The native float, what the ERC-20 balances on this chain add up to,
    ///  is `totalSupply() - totalBridged()`.
    function totalBridged() external view returns (uint256);

    /// @notice Returns the amount held in transit against a cross-chain validation: its burn leg landed, its mint
    ///  leg has not. Zero once settled, or for a validation that never held anything.
    /// @param validationId the validation the burn leg consumed
    function inTransitOf(uint256 validationId) external view returns (uint256);

    /// @notice Returns the sum of every in-transit hold: the part of `totalBridged` no wallet currently holds.
    function totalInTransit() external view returns (uint256);

    /// @notice Applies a settled validation to the ledger, once, by the shape of its wallets: a native `to` lands
    ///  on that holder's free balance, two satellite wallets are a bridged transfer, both under `validationId`.
    ///  `from` is always a satellite wallet, the compliance refusing to issue a validation out of a native one, so
    ///  the position a settlement debits is one the executing satellite held all along.
    /// @dev Callable by the bound compliance only, which classified the settlement against the validation it
    ///  issued; reverts with `OnlyBoundCompliance` otherwise. Reverts with `InsufficientBridgedBalance` when
    ///  `from`'s position no longer covers `amount`, which leaves the settlement deliverable again. Reverts
    ///  with `EnforcedPause` while the token is paused, so a halt stops satellite settlements too. Bypasses
    ///  `_update`, like every ledger transition.
    /// @param from the ERC-7930 envelope of the sender, a satellite wallet
    /// @param to the ERC-7930 envelope of the recipient
    /// @param amount the exact amount the satellite executed
    /// @param validationId the validation the settlement consumed
    function settleValidation(bytes calldata from, bytes calldata to, uint256 amount, uint256 validationId) external;

    /// @notice Debits `amount` from `from`'s bridged position and holds it in transit against `validationId`:
    ///  the burn leg of a cross-chain validation landed and proves the satellite burned it, so the wallet must
    ///  not be issued or recalled against it while the mint leg is in flight. `totalBridged` and `totalSupply`
    ///  do not move; the amount is still bridged and still the sender's. `settleValidation` for the same id
    ///  later credits the recipient from the hold instead of debiting `from` again.
    /// @dev Callable by the bound compliance only; reverts with `OnlyBoundCompliance` otherwise. Reverts with
    ///  `TransitAlreadyHeld` when the validation already holds an amount, and with `InsufficientBridgedBalance`
    ///  when `from`'s position no longer covers `amount`, which leaves the burn leg deliverable again. Reverts
    ///  with `EnforcedPause` while the token is paused.
    /// @param from the ERC-7930 envelope of the sender, a satellite wallet
    /// @param amount the exact amount the satellite burned
    /// @param validationId the validation the burn leg consumed
    function holdInTransit(bytes calldata from, uint256 amount, uint256 validationId) external;

    /// @dev Puts the amount held for `validationId` back on `to`, the satellite wallet it was burned from: the
    ///  mint leg never came and the compliance gave up on the pair. Callable by the bound compliance alone.
    function returnInTransit(bytes calldata to, uint256 validationId) external;

}
