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

import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";

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

    /// @dev Returns the ONCHAINID IdentityFactory whose type record backs per-type claim topic
    /// resolution. Baked into the implementation at construction, so changing it takes a new
    /// implementation published through the beacon. `identityTypeOf` on it returns 0 for identities
    /// it did not mint, which resolve to the default claim topics.
    function identityFactory() external view returns (IIdentityFactory);

    /// @dev Adds a claim topic to the override set of an identity type.
    ///
    /// A non-empty override set fully REPLACES the default claim topics inside `isVerified` for
    /// identities of that type. It is not additive. Later changes to the default topics do not reach
    /// types holding an override; a topic meant for everyone must be added to each override too.
    ///
    /// The identity type checked by `isVerified` is the IdentityFactory record (`identityTypeOf`),
    /// never what the identity contract says about itself.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - `identityType` must not be 0 (reserved for "unknown", which always resolves to the default
    ///   topics); otherwise the call reverts with `InvalidIdentityType`.
    /// - The override set must hold fewer than 15 topics; otherwise the call reverts with
    ///   `MaxClaimTopicsReached`.
    /// - The topic must not already be in the set; otherwise the call reverts with
    ///   `ClaimTopicAlreadyExists`.
    ///
    /// Emits a `ClaimTopicAddedForIdentityType` event upon successful execution.
    /// @param identityType the ONCHAINID identity type the topic is required for
    /// @param claimTopic the claim topic to require for that identity type
    function addClaimTopicForIdentityType(uint256 identityType, uint256 claimTopic) external;

    /// @dev Removes a claim topic from the override set of an identity type.
    ///
    /// Once the set becomes empty, identities of that type fall back to the default claim topics.
    /// Removing a topic that is not in the set is a silent no-op, mirroring `removeClaimTopic`.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - `identityType` must not be 0; otherwise the call reverts with `InvalidIdentityType`.
    ///
    /// Emits a `ClaimTopicRemovedForIdentityType` event when a topic is actually removed.
    /// @param identityType the ONCHAINID identity type the topic is no longer required for
    /// @param claimTopic the claim topic to remove for that identity type
    function removeClaimTopicForIdentityType(uint256 identityType, uint256 claimTopic) external;

    /// @dev Returns the override claim topics registered for an identity type.
    ///
    /// An empty array means identities of that type verify against the default `getClaimTopics()`.
    /// @param identityType the ONCHAINID identity type to query
    function getClaimTopicsForIdentityType(uint256 identityType) external view returns (uint256[] memory);

}
