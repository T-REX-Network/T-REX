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

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";

import { IERC3643IdentityRegistry } from "../ERC-3643/IERC3643IdentityRegistry.sol";
import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { ITREXRegistry } from "../registry/interface/ITREXRegistry.sol";

/**
 * @title TokenRecoveryLib
 * @dev The registry side of the token's wallet recovery, deployed once and linked.
 *
 * Recovery is rare and its registry conversation is external calls and ABI encoding the token would
 * otherwise carry on every deployment. The token reaches this by DELEGATECALL, so the registry sees the
 * token as its caller, exactly as before. The balance and freeze migration stays in the token, since it
 * is the token's own ERC-20 and ERC-3643 state.
 */
library TokenRecoveryLib {

    /// @dev The T-REX recovery preconditions: a wallet may not be recovered onto itself, there must be
    ///  something to recover, at least one of the two wallets must already be known to the registry, and a
    ///  known new wallet must already belong to `investorOnchainId`. Reverts in that order.
    /// @param lostBalance the lost wallet's current balance, read by the token
    function checkRecovery(
        IERC3643IdentityRegistry registry,
        address lostWallet,
        address newWallet,
        address investorOnchainId,
        uint256 lostBalance
    ) external view {
        require(lostWallet != newWallet, ErrorsLib.SameWalletRecovery());
        require(lostBalance != 0, ErrorsLib.NoTokenToRecover());

        require(registry.contains(lostWallet) || registry.contains(newWallet), ErrorsLib.RecoveryNotPossible());
        require(
            !registry.contains(newWallet) || registry.identity(newWallet) == IIdentity(investorOnchainId),
            ErrorsLib.RecoveryNotPossible()
        );
    }

    /// @dev The new wallet is registered only when it resolves nowhere, so a wallet the global registry
    ///  already binds keeps following that binding rather than a local copy. Only local entries can be
    ///  deleted, so the lost wallet is reported for deletion only when it is locally registered. Country is
    ///  passed as 0 rather than read from the lost wallet, because T-REX stores none.
    /// @return lostWalletLocal whether the token must delete the lost wallet once compliance has been told
    function registerRecoveredWallet(
        IERC3643IdentityRegistry registry,
        address lostWallet,
        address newWallet,
        address investorOnchainId
    ) external returns (bool lostWalletLocal) {
        if (!registry.contains(newWallet)) {
            registry.registerIdentity(newWallet, IIdentity(investorOnchainId), 0);
        }
        return ITREXRegistry(address(registry)).isLocallyRegistered(lostWallet);
    }

}
