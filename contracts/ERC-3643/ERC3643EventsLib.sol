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

library ERC3643EventsLib {

    // ============================================
    // IERC3643 Events
    // ============================================

    event UpdatedTokenInformation(
        string _newName, string _newSymbol, uint8 _newDecimals, string _newVersion, address indexed _newOnchainID
    );

    event IdentityRegistryAdded(address indexed _identityRegistry);

    event ComplianceAdded(address indexed _compliance);

    event RecoverySuccess(address indexed _lostWallet, address indexed _newWallet, address indexed _investorOnchainID);

    /// @dev `_owner` records the actor that set the frozen status (`_msgSender()`). When the call is
    /// routed through `AccessManager.execute`, `_msgSender()` is the AccessManager, so this field
    /// reflects the executing contract rather than the originator address (the EOA or contract behind
    /// the role). Consumers that need the originator address must read it from the AccessManager
    /// execution context, not here.
    event AddressFrozen(address indexed _userAddress, bool indexed _isFrozen, address indexed _owner);

    event TokensFrozen(address indexed _userAddress, uint256 _amount);

    event TokensUnfrozen(address indexed _userAddress, uint256 _amount);

    // ============================================
    // IERC3643Compliance Events
    // ============================================

    event TokenBound(address _token);

    event TokenUnbound(address _token);

    // ============================================
    // IERC3643IdentityRegistry Events
    // ============================================

    event ClaimTopicsRegistrySet(address indexed _claimTopicsRegistry);

    event IdentityStorageSet(address indexed _identityStorage);

    event TrustedIssuersRegistrySet(address indexed _trustedIssuersRegistry);

    event IdentityRegistered(address indexed _investorAddress, IIdentity indexed _identity);

    event IdentityRemoved(address indexed _investorAddress, IIdentity indexed _identity);

    event IdentityUpdated(IIdentity indexed _oldIdentity, IIdentity indexed _newIdentity);

    event CountryUpdated(address indexed _investorAddress, uint16 indexed _country);

    // ============================================
    // IERC3643IdentityRegistryStorage Events
    // ============================================

    event IdentityStored(address indexed _investorAddress, IIdentity indexed _identity);

    event IdentityUnstored(address indexed _investorAddress, IIdentity indexed _identity);

    event IdentityModified(IIdentity indexed _oldIdentity, IIdentity indexed _newIdentity);

    event CountryModified(address indexed _investorAddress, uint16 indexed _country);

    event IdentityRegistryBound(address indexed _identityRegistry);

    event IdentityRegistryUnbound(address indexed _identityRegistry);

    // ============================================
    // IERC3643ClaimTopicsRegistry Events
    // ============================================

    event ClaimTopicAdded(uint256 indexed _claimTopic);

    event ClaimTopicRemoved(uint256 indexed _claimTopic);

    // ============================================
    // IERC3643TrustedIssuersRegistry Events
    // ============================================

    event TrustedIssuerAdded(address indexed _trustedIssuer, uint256[] _claimTopics);

    event TrustedIssuerRemoved(address indexed _trustedIssuer);

    event ClaimTopicsUpdated(address indexed _trustedIssuer, uint256[] _claimTopics);

}
