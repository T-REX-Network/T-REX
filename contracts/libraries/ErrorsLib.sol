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

/// @dev Errors of the ERC-3643 standard surface are declared canonically in
///  {ERC3643ErrorsLib}, inside the standard layer, because the standard bases may not import from the
///  T-REX layer (issue #65). The names below are re-declared here for the T-REX layer and for tests.
///  Solidity identifies errors by selector, so a re-declaration with the same signature is the same
///  error on the wire; `forge lint` reporting some of them as unused only means no T-REX-layer contract
///  raises them any more, not that they are unreachable.
library ErrorsLib {

    // Common Errors
    error ZeroAddress();
    error ZeroValue();
    error ArraySizeLimited(uint256 maxSize);
    error ArrayLengthMismatch();
    error InvalidImplementationAuthority();

    // Token Errors
    error AmountAboveFrozenTokens(uint256 amount, uint256 maxAmount);
    error ComplianceNotFollowed();
    error DecimalsOutOfRange(uint256 decimals);
    error EmptyString();
    error FrozenWallet(address user);
    error ComplianceAlreadyBoundToToken();
    error InvalidCompliance();
    error InvalidIdentityRegistry();
    error NoTokenToRecover();
    error NotLinkedIdentity(address from, address caller);
    error RecoveryNotPossible();
    error SameWalletRecovery();
    error SpenderNotAllowed(address spender, address from, address to, uint256 value);
    error UnverifiedIdentity();

    // ModularCompliance Errors
    error AddressNotATokenBoundToComplianceContract();
    error ComplianceNotSuitableForBindingToModule(address module);
    error InvalidModuleCapabilities(uint256 capabilities);
    error MaxModulesReached(uint256 maxValue);
    error ModuleAlreadyBound();
    error ModuleHasNoCapabilities();
    error ModuleNotBound();
    error OnlyOwnerOrTokenCanCall();
    error TokenNotBound();

    // Module Errors
    error ComplianceNotBound();
    error ComplianceAlreadyBound();
    error OnlyBoundComplianceCanCall();
    error OnlyComplianceContractCanCall();
    error SpenderAlreadyAllowed(address spender);
    error SpenderNotListed(address spender);

    // TREXFactory Errors
    error AuthorityMismatch();
    error StorageAuthorityMismatch(address identityRegistryStorage, address expected, address actual);
    error AccessManagerNotAContract(address accessManager);
    error InvalidAccessManagerAdmin();
    error InvalidClaimPattern();
    error InvalidCompliancePattern();
    error MaxClaimIssuersReached(uint256 max);
    /// @dev The IdentityFactory already binds the predicted token address to a different identity.
    error TokenIdentityAlreadyBound(address token, address boundIdentity);
    error TokenAlreadyDeployed();
    error IsolatedSuiteCannotReuseIRS();

    // ClaimTopicsRegistry Errors
    error ClaimTopicAlreadyExists();
    error InvalidIdentityType();

    // IdentityRegistry Errors
    error EligibilityChecksDisabledAlready();
    error EligibilityChecksEnabledAlready();
    error InvalidIdentityRegistryStorage();

    // IdentityRegistryStorage Errors
    error AddressAlreadyStored();
    error AddressNotYetStored();
    error IdentityRegistryNotStored();
    error MaxIRByIRSReached(uint256 max);

    // AccessManagerSetupLib Errors
    error NotAssigned(address target);
    error PendingDelayChange(address account, uint64 role);
    error PendingRoleGrant(address account, uint64 role);
    error RoleNotHeld(address account, uint64 role);

    // RolesLib Errors
    error InvalidDomain();

    // TREXAccessManager Errors
    error DomainNotFound(uint32 domainId);

    // TrustedIssuersRegistry Errors
    error ClaimTopicsCannotBeEmpty();
    error MaxClaimTopicsReached(uint256 max);
    error MaxTrustedIssuersReached(uint256 max);
    error NotATrustedIssuer();
    error TrustedClaimTopicsCannotBeEmpty();
    error TrustedIssuerAlreadyExists();

    // TREXImplementationAuthority Errors
    error EmptyImplementations();
    error UnknownVersion();
    error VersionAlreadyPublished();
    error VersionNotNewer();

    // TREXRegistry Errors
    error Deprecated();

}
