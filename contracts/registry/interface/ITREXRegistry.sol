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

pragma solidity ^0.8.30;

import { IERC3643ClaimTopicsRegistry } from "../../ERC-3643/IERC3643ClaimTopicsRegistry.sol";
import { IERC3643IdentityRegistry } from "../../ERC-3643/IERC3643IdentityRegistry.sol";
import { IERC3643TrustedIssuersRegistry } from "../../ERC-3643/IERC3643TrustedIssuersRegistry.sol";

interface ITREXRegistry is IERC3643IdentityRegistry, IERC3643TrustedIssuersRegistry, IERC3643ClaimTopicsRegistry {

    /// @dev Disables the eligibility checks for token transfers and other operations.
    ///
    /// Once disabled, all users are considered verified by `isVerified`, bypassing the
    /// required-claims / trusted-issuer verification.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - The eligibility checks must not already be disabled; otherwise the call reverts with
    ///   `EligibilityChecksDisabledAlready`.
    ///
    /// Emits an `EligibilityChecksDisabled` event upon successful execution.
    function disableEligibilityChecks() external;

    /// @dev Enables the eligibility checks for token transfers and other operations.
    ///
    /// Resumes the full claims / trusted-issuer verification inside `isVerified`.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - The eligibility checks must currently be disabled; otherwise the call reverts with
    ///   `EligibilityChecksEnabledAlready`.
    ///
    /// Emits an `EligibilityChecksEnabled` event upon successful execution.
    function enableEligibilityChecks() external;

    /// @notice Returns true when the wallet has an identity stored locally in this registry,
    /// ignoring the global identity registry fallback.
    function isLocallyRegistered(address userAddress) external view returns (bool);

    /// @notice Binds this registry to the token it serves.
    /// @dev A registry serves exactly one token. Callable by the token itself while unbound, or by the owner.
    /// @param token the token this registry serves
    function bindToken(address token) external;

    /// @notice Reconciles the cached country of an investor against their residence claim.
    /// @dev Callable only by the bound token. Idempotent: nothing pending writes nothing. A claim that
    /// stopped resolving keeps the cached value and flags the identity.
    /// @param userAddress the wallet of the investor
    /// @return topic claim topic of the reconciled attribute
    /// @return oldValue value the compliance aggregates are built on
    /// @return newValue value now cached
    /// @return moved true when the cached value changed and compliance must move the position
    function reconcileAttribute(address userAddress)
        external
        returns (uint256 topic, uint16 oldValue, uint16 newValue, bool moved);

    /// @notice Claim topic carrying the investor's attested residence.
    function COUNTRY_CLAIM_TOPIC() external view returns (uint256);

    /// @notice Returns the token this registry is bound to, or the zero address when it serves none.
    function tokenBound() external view returns (address);

    /// @notice Returns the country attested in the investor's residence claim right now.
    /// @dev Disagreeing with `investorCountry` means a reconcile is pending.
    /// @param userAddress the wallet of the investor
    function attestedCountry(address userAddress) external view returns (uint16);

    /// @notice Returns the cached value of a claim-derived attribute.
    /// @param identity the identity the attribute belongs to
    /// @param topic claim topic identifying the attribute
    function cachedAttribute(address identity, uint256 topic) external view returns (uint16);

    /// @notice Returns true when the identity's attesting claim no longer resolves.
    /// @dev The cached value stays counted; the flag marks the identity for review.
    /// @param identity the identity the attribute belongs to
    /// @param topic claim topic identifying the attribute
    function isAttributeFlagged(address identity, uint256 topic) external view returns (bool);

}
