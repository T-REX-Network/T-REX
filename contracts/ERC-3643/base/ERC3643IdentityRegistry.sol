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

import { IClaimIssuer } from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";
import { LowLevelCall } from "@openzeppelin/contracts/utils/LowLevelCall.sol";

import { ERC3643ErrorsLib } from "../ERC3643ErrorsLib.sol";
import { IERC3643ClaimTopicsRegistry } from "../IERC3643ClaimTopicsRegistry.sol";
import { IERC3643IdentityRegistry } from "../IERC3643IdentityRegistry.sol";
import { IERC3643IdentityRegistryStorage } from "../IERC3643IdentityRegistryStorage.sol";
import { IERC3643TrustedIssuersRegistry } from "../IERC3643TrustedIssuersRegistry.sol";

/// @title ERC3643IdentityRegistry
/// @dev The ERC-3643 Identity Registry surface and nothing else, over its own ERC-7201 namespace.
/// Collaborators are reached through `_identityStorage`, `_issuersRegistry` and `_topicsRegistry`, so a
/// registry serving all three surfaces overrides them to return itself. `_isVerified` is written against
/// `_requiredClaimTopics` and `_trustedIssuersForTopic`, so extensions can change which topics and
/// issuers apply without rewriting the claim loop.
abstract contract ERC3643IdentityRegistry is IERC3643IdentityRegistry {

    /// @custom:storage-location erc7201:erc3643.storage.IdentityRegistry
    struct ERC3643IdentityRegistryStorage {
        IERC3643IdentityRegistryStorage identityStorage;
        IERC3643TrustedIssuersRegistry issuersRegistry;
        IERC3643ClaimTopicsRegistry topicsRegistry;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.IdentityRegistry")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant IDENTITY_REGISTRY_STORAGE_LOCATION =
        0x7677ac510b853691f250873636359d7d7673c26ecc94050f9c8f5810c4b61e00;

    /// @inheritdoc IERC3643IdentityRegistry
    function setIdentityRegistryStorage(address _identityRegistryStorage) external virtual {
        _authorizeRegistryUpdate(_identityRegistryStorage);
        _setIdentityRegistryStorage(_identityRegistryStorage);
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function setClaimTopicsRegistry(address _claimTopicsRegistry) external virtual {
        _authorizeRegistryUpdate(_claimTopicsRegistry);
        _setClaimTopicsRegistry(_claimTopicsRegistry);
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function setTrustedIssuersRegistry(address _trustedIssuersRegistry) external virtual {
        _authorizeRegistryUpdate(_trustedIssuersRegistry);
        _setTrustedIssuersRegistry(_trustedIssuersRegistry);
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function registerIdentity(address _userAddress, IIdentity _identity, uint16 _country) external virtual {
        _authorizeIdentityUpdate();
        _registerIdentity(_userAddress, _identity, _country);
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function deleteIdentity(address _userAddress) external virtual {
        _authorizeIdentityUpdate();
        _deleteIdentity(_userAddress);
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function updateCountry(address _userAddress, uint16 _country) external virtual {
        _authorizeIdentityUpdate();
        _updateCountry(_userAddress, _country);
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function updateIdentity(address _userAddress, IIdentity _identity) external virtual {
        _authorizeIdentityUpdate();
        _updateIdentity(_userAddress, _identity);
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function batchRegisterIdentity(
        address[] calldata _userAddresses,
        IIdentity[] calldata _identities,
        uint16[] calldata _countries
    ) external virtual {
        _authorizeIdentityUpdate();
        require(
            _userAddresses.length == _identities.length && _userAddresses.length == _countries.length,
            ERC3643ErrorsLib.ArrayLengthMismatch()
        );
        for (uint256 i = 0; i < _userAddresses.length; i++) {
            _registerIdentity(_userAddresses[i], _identities[i], _countries[i]);
        }
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function contains(address _userAddress) external view virtual returns (bool) {
        return address(_identityOf(_userAddress)) != address(0);
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function isVerified(address _userAddress) external view virtual returns (bool) {
        return _isVerified(_userAddress);
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function identity(address _userAddress) external view virtual returns (IIdentity) {
        return _identityOf(_userAddress);
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function investorCountry(address _userAddress) external view virtual returns (uint16) {
        return _investorCountry(_userAddress);
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function identityStorage() external view virtual returns (IERC3643IdentityRegistryStorage) {
        return _identityStorage();
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function issuersRegistry() external view virtual returns (IERC3643TrustedIssuersRegistry) {
        return _issuersRegistry();
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function topicsRegistry() external view virtual returns (IERC3643ClaimTopicsRegistry) {
        return _topicsRegistry();
    }

    /// @dev Authorization hook for the identity-writing functions. Left abstract on purpose: the
    ///  standard specifies no access model.
    function _authorizeIdentityUpdate() internal virtual;

    /// @dev Authorization hook for the three collaborator setters. Receives the new address so derived
    ///  contracts can apply per-target checks (interface support, a shared authority).
    function _authorizeRegistryUpdate(address newRegistry) internal virtual;

    /// @dev Points this registry at a new identity storage.
    function _setIdentityRegistryStorage(address identityRegistryStorage) internal virtual {
        require(identityRegistryStorage != address(0), ERC3643ErrorsLib.ZeroAddress());
        _erc3643IdentityRegistryStorage().identityStorage = IERC3643IdentityRegistryStorage(identityRegistryStorage);
        emit IdentityStorageSet(identityRegistryStorage);
    }

    /// @dev Points this registry at a new claim topics registry.
    function _setClaimTopicsRegistry(address claimTopicsRegistry) internal virtual {
        require(claimTopicsRegistry != address(0), ERC3643ErrorsLib.ZeroAddress());
        _erc3643IdentityRegistryStorage().topicsRegistry = IERC3643ClaimTopicsRegistry(claimTopicsRegistry);
        emit ClaimTopicsRegistrySet(claimTopicsRegistry);
    }

    /// @dev Points this registry at a new trusted issuers registry.
    function _setTrustedIssuersRegistry(address trustedIssuersRegistry) internal virtual {
        require(trustedIssuersRegistry != address(0), ERC3643ErrorsLib.ZeroAddress());
        _erc3643IdentityRegistryStorage().issuersRegistry = IERC3643TrustedIssuersRegistry(trustedIssuersRegistry);
        emit TrustedIssuersRegistrySet(trustedIssuersRegistry);
    }

    /// @dev Registers an identity through the identity storage.
    function _registerIdentity(address userAddress, IIdentity userIdentity, uint16 country) internal virtual {
        _identityStorage().addIdentityToStorage(userAddress, userIdentity, country);
        emit IdentityRegistered(userAddress, userIdentity);
    }

    /// @dev Removes an identity through the identity storage.
    function _deleteIdentity(address userAddress) internal virtual {
        IIdentity oldIdentity = _identityOf(userAddress);
        _identityStorage().removeIdentityFromStorage(userAddress);
        emit IdentityRemoved(userAddress, oldIdentity);
    }

    /// @dev Updates an investor's country through the identity storage.
    function _updateCountry(address userAddress, uint16 country) internal virtual {
        _identityStorage().modifyStoredInvestorCountry(userAddress, country);
        emit CountryUpdated(userAddress, country);
    }

    /// @dev Replaces an investor's identity contract through the identity storage.
    function _updateIdentity(address userAddress, IIdentity userIdentity) internal virtual {
        IIdentity oldIdentity = _identityOf(userAddress);
        _identityStorage().modifyStoredIdentity(userAddress, userIdentity);
        emit IdentityUpdated(oldIdentity, userIdentity);
    }

    /// @dev Whether `userAddress` holds a valid claim, from a trusted issuer, for every required topic.
    ///
    ///  An identity answers `getClaim`, so the issuer it returns is untrusted input: only a claim from
    ///  `trustedIssuer` hashes to `claimId`. Validity is therefore asked of the configured issuer, never
    ///  of the address the identity supplied. The call is made with a bounded low-level staticcall so a
    ///  hostile or broken issuer cannot halt verification by reverting or returning oversized data.
    function _isVerified(address userAddress) internal view virtual returns (bool) {
        IIdentity userIdentity = _identityOf(userAddress);
        if (address(userIdentity) == address(0)) return false;

        uint256[] memory requiredClaimTopics = _requiredClaimTopics(userIdentity);
        if (requiredClaimTopics.length == 0) return true;

        for (uint256 i = 0; i < requiredClaimTopics.length; i++) {
            if (!_hasValidClaimForTopic(userIdentity, requiredClaimTopics[i])) return false;
        }
        return true;
    }

    /// @dev Whether `userIdentity` holds a valid claim for `claimTopic` from any issuer trusted for it.
    function _hasValidClaimForTopic(IIdentity userIdentity, uint256 claimTopic) internal view virtual returns (bool) {
        address[] memory trustedIssuersForTopic = _trustedIssuersForTopic(claimTopic);
        if (trustedIssuersForTopic.length == 0) return false;

        for (uint256 j = 0; j < trustedIssuersForTopic.length; j++) {
            address trustedIssuer = trustedIssuersForTopic[j];
            bytes32 claimId = keccak256(abi.encode(trustedIssuer, claimTopic));
            (uint256 foundClaimTopic,, address issuer, bytes memory sig, Structs.ClaimData memory data,) =
                userIdentity.getClaim(claimId);

            if (foundClaimTopic != claimTopic || issuer != trustedIssuer) continue;

            (bool success, bytes32 result,) = LowLevelCall.staticcallReturn64Bytes(
                trustedIssuer, abi.encodeCall(IClaimIssuer.isClaimValid, (userIdentity, claimTopic, sig, data))
            );
            if (success && result != bytes32(0)) return true;
        }
        return false;
    }

    /// @dev The claim topics `userIdentity` must satisfy. Defaults to the configured topics registry.
    ///  Extensions override this to vary the requirement (per identity type, for instance) without
    ///  reimplementing the verification loop.
    function _requiredClaimTopics(
        IIdentity /* userIdentity */
    )
        internal
        view
        virtual
        returns (uint256[] memory)
    {
        return _topicsRegistry().getClaimTopics();
    }

    /// @dev The issuers trusted for `claimTopic`. Defaults to the configured issuers registry.
    function _trustedIssuersForTopic(uint256 claimTopic) internal view virtual returns (address[] memory) {
        return _issuersRegistry().getTrustedIssuersForClaimTopic(claimTopic);
    }

    /// @dev The identity of a wallet, read through the identity storage.
    function _identityOf(address userAddress) internal view virtual returns (IIdentity) {
        return _identityStorage().storedIdentity(userAddress);
    }

    /// @dev The country of a wallet, read through the identity storage.
    function _investorCountry(address userAddress) internal view virtual returns (uint16) {
        return _identityStorage().storedInvestorCountry(userAddress);
    }

    /// @dev The identity storage this registry writes through.
    function _identityStorage() internal view virtual returns (IERC3643IdentityRegistryStorage) {
        return _erc3643IdentityRegistryStorage().identityStorage;
    }

    /// @dev The trusted issuers registry backing verification. A consolidated registry overrides this
    ///  to return itself.
    function _issuersRegistry() internal view virtual returns (IERC3643TrustedIssuersRegistry) {
        return _erc3643IdentityRegistryStorage().issuersRegistry;
    }

    /// @dev The claim topics registry backing verification. A consolidated registry overrides this
    ///  to return itself.
    function _topicsRegistry() internal view virtual returns (IERC3643ClaimTopicsRegistry) {
        return _erc3643IdentityRegistryStorage().topicsRegistry;
    }

    function _erc3643IdentityRegistryStorage() internal pure returns (ERC3643IdentityRegistryStorage storage s) {
        assembly ("memory-safe") {
            s.slot := IDENTITY_REGISTRY_STORAGE_LOCATION
        }
    }

}
