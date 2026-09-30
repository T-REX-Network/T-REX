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

import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import { IERC3643Compliance } from "../ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "../ERC-3643/IERC3643IdentityRegistry.sol";
import { IModularCompliance } from "../compliance/modular/IModularCompliance.sol";
import { ErrorsLib } from "../libraries/ErrorsLib.sol";

/**
 * @title TokenGuardsLib
 * @dev The checks behind the token's collaborator setters, deployed once and linked. The token reaches
 * this by DELEGATECALL, so every contract it talks to sees the token as its caller. Unbinding the current
 * compliance happens here; writing the new pointer, the bind and the event stay in the token.
 */
library TokenGuardsLib {

    /// @dev A token with supply keeps its registry, and the new one must advertise the standard interface.
    ///  Reverts `TokenCirculating`, then `InvalidIdentityRegistry`.
    /// @param current the registry the token has now, zero during initialization
    /// @param supply the token's total supply, native and bridged
    function checkIdentityRegistry(address current, address identityRegistryAddress, uint256 supply) external view {
        require(current == address(0) || supply == 0, ErrorsLib.TokenCirculating());
        require(
            ERC165Checker.supportsInterface(identityRegistryAddress, type(IERC3643IdentityRegistry).interfaceId),
            ErrorsLib.InvalidIdentityRegistry()
        );
    }

    /// @dev A token with supply keeps its compliance; the new one must advertise the standard interface and
    ///  be bound to no token; the current one, if any, is unbound. The token then writes the pointer and
    ///  binds. Reverts `TokenCirculating`, then `InvalidCompliance`, then `ComplianceAlreadyBoundToToken`.
    /// @param current the compliance the token has now, zero during initialization
    /// @param supply the token's total supply, native and bridged
    function prepareCompliance(address current, address complianceAddress, uint256 supply) external {
        require(current == address(0) || supply == 0, ErrorsLib.TokenCirculating());

        // Checked before getTokenBound() so a wrong contract gives a named error.
        require(
            ERC165Checker.supportsInterface(complianceAddress, type(IERC3643Compliance).interfaceId),
            ErrorsLib.InvalidCompliance()
        );

        address boundToken = IModularCompliance(complianceAddress).getTokenBound();
        require(boundToken == address(0), ErrorsLib.ComplianceAlreadyBoundToToken());

        if (current != address(0)) {
            IERC3643Compliance(current).unbindToken(address(this));
        }
    }

}
