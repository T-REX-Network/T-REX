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

library ErrorsLib {

    // Common Errors
    error ZeroAddress();
    error ZeroValue();
    error ArraySizeLimited(uint256 maxSize);
    error InvalidImplementationAuthority();

    // Token Errors
    error AmountAboveFrozenTokens(uint256 amount, uint256 maxAmount);
    error ComplianceNotFollowed();
    error DecimalsOutOfRange(uint256 decimals);
    error EmptyString();
    error FrozenWallet(address user);
    error ComplianceAlreadyBoundToToken();
    error NoTokenToRecover();
    error RecoveryNotPossible();
    error SameWalletRecovery();
    error SpenderNotAllowed(address spender, address from, address to, uint256 value);
    error UnverifiedIdentity();
    /// @dev Only a wallet on another chain can hold a bridged position; this envelope designates this chain.
    error NotASatelliteWallet(bytes wallet);
    /// @dev The bridged position on the wallet is smaller than the amount to move out of it.
    error InsufficientBridgedBalance(bytes wallet, uint256 balance, uint256 needed);

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
    error InvalidClaimPattern();
    error InvalidCompliancePattern();
    error MaxClaimIssuersReached(uint256 max);
    error MaxAgentsReached(uint256 max);
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

    // TransferValidation Errors
    /// @dev A validity or reconciliation window must be positive.
    error ZeroDuration();
    /// @dev Issuance involving this chain is paused, by the manager or by a late reconciliation.
    error ValidationIssuancePaused(bytes32 chainKey);
    /// @dev Unpausing a chain that is not paused.
    error ValidationIssuanceNotPaused(bytes32 chainKey);
    /// @dev Issuance needs a validity window; none was configured.
    error ValidityWindowNotSet();
    /// @dev Issuance toward this chain needs its reconciliation window; none was configured.
    error ReconciliationWindowNotSet(bytes32 chainKey);
    /// @dev The requested range is inverted.
    error InvalidRequestedRange(uint256 requestedMin, uint256 requestedMax);
    /// @dev The balance cap, the modules or the clamp left no amount to authorize.
    error EmptyValidationRange(uint256 min, uint256 max);
    /// @dev The caller is neither the native wallet, its identity, nor authorised by the AccessManager.
    error NotAuthorizedForWallet(address caller, bytes wallet);
    /// @dev `from` has no identity, or `to` is not eligible for new activity.
    error UnverifiedWallet(bytes wallet);
    /// @dev Both wallets live on the reference chain: nothing for a satellite to execute.
    error NoSatelliteLeg();
    /// @dev The id was never issued by this compliance.
    error UnknownValidation(uint256 validationId);
    /// @dev Only a stored `Pending` validation can be discarded; `status` is the `ValidationStatus` found instead.
    error ValidationNotDiscardable(uint256 validationId, uint8 status);
    /// @dev The validation's release deadline has not passed yet.
    error ValidationNotReleasable(uint256 validationId, uint64 releaseAt);
    // Interop Errors
    error NonCanonicalInteroperableAddress(bytes envelope);
    error ChainNotOpen(bytes32 chainKey);
    error GatewayNotRouted(address gateway, bytes32 chainKey);
    error GatewayNotPinned(address gateway, uint256 validationId, bytes32 chainKey);
    error GatewayNotTrusted(address gateway);
    error InvalidChainReference(bytes2 chainType, bytes chainReference);
    error InvalidPeer(bytes peer);
    error MessageAlreadyReceived(address gateway, bytes32 receiveId);
    error MessageTypeNotInbound(uint8 messageType);
    error RegistryNotSet();
    error PeerChainMismatch(bytes32 chainKey, bytes32 peerChainKey);
    error SenderNotPeer(bytes32 chainKey, bytes sender);
    error UnknownMessageType(uint8 messageType);
    error UnsupportedMessageVersion(uint8 messageVersion);
    error ValidationAlreadyRouted(uint256 validationId, bytes32 chainKey, address gateway);

}
