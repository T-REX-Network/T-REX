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
import { IClaimIssuer } from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";
import { LowLevelCall } from "@openzeppelin/contracts/utils/LowLevelCall.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { ERC3643EventsLib } from "../../ERC-3643/ERC3643EventsLib.sol";
import { IERC3643ClaimTopicsRegistry } from "../../ERC-3643/IERC3643ClaimTopicsRegistry.sol";
import { IERC3643IdentityRegistry } from "../../ERC-3643/IERC3643IdentityRegistry.sol";
import { IERC3643IdentityRegistryStorage } from "../../ERC-3643/IERC3643IdentityRegistryStorage.sol";
import { IERC3643TrustedIssuersRegistry } from "../../ERC-3643/IERC3643TrustedIssuersRegistry.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { AccessManagedOwnableUpgradeable } from "../../utils/AccessManagedOwnableUpgradeable.sol";
import { IIdentityRegistryStorage } from "../interface/IIdentityRegistryStorage.sol";
import { ITREXRegistry } from "../interface/ITREXRegistry.sol";

/// @title TREXRegistry
/// @notice Eligibility registry holding the suite's identities, trusted issuers and required claim
///  topics in a single deployment.
contract TREXRegistry is ITREXRegistry, AccessManagedOwnableUpgradeable {

    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    /// @custom:storage-location erc7201:erc3643.storage.TREXRegistry
    struct Storage {
        // ----- IdentityRegistry storage -----
        IIdentityRegistryStorage tokenIdentityStorage;
        bool checksDisabled;

        /// @dev ONCHAINID IdentityFactory used by `isVerified` to read an identity's type. The
        ///  factory records the type once at minting and never updates it, so it is a safer source
        ///  than asking the identity contract itself.
        IIdentityFactory identityFactory;
        // ----- TrustedIssuersRegistry storage -----
        /// @dev Set containing all TrustedIssuers identity contract addresses.
        EnumerableSet.AddressSet trustedIssuers;

        /// @dev Mapping between a trusted issuer address and its corresponding claimTopics.
        mapping(address issuer => EnumerableSet.UintSet) trustedIssuerClaimTopics;

        /// @dev Mapping between a claim topic and the allowed trusted issuers for it.
        mapping(uint256 topic => EnumerableSet.AddressSet) claimTopicsToTrustedIssuers;

        // ----- ClaimTopicsRegistry storage -----
        EnumerableSet.UintSet claimTopics;

        /// @dev Per-identity-type claim topic overrides; a non-empty set fully replaces `claimTopics`
        ///  for identities of that type inside `isVerified`.
        mapping(uint256 identityType => EnumerableSet.UintSet claimTopics) claimTopicsByIdentityType;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.TREXRegistry")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant STORAGE_LOCATION = 0x5fe6836edad2306552d236f378d4a0a2ef1c78da81818168b2b776323acb4300;

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract
    /// @param identityStorageAddress the address of the (external) identity registry storage
    /// @param accessManagerAddress the address of the access manager
    /// @param identityFactoryAddress the ONCHAINID IdentityFactory whose type record backs per-type
    ///        claim topic resolution
    /// @param initialTopics the claim topics required at deployment
    /// @param issuers the trusted issuers to register at deployment
    /// @param issuerClaims the claim topics each entry of `issuers` is trusted for
    function init(
        address identityStorageAddress,
        address accessManagerAddress,
        address identityFactoryAddress,
        uint256[] memory initialTopics,
        address[] memory issuers,
        uint256[][] memory issuerClaims
    ) external initializer {
        require(
            identityStorageAddress != address(0) && accessManagerAddress != address(0)
                && identityFactoryAddress != address(0),
            ErrorsLib.ZeroAddress()
        );
        require(issuers.length == issuerClaims.length, ErrorsLib.InvalidClaimPattern());

        Storage storage s = _getStorage();
        s.tokenIdentityStorage = IIdentityRegistryStorage(identityStorageAddress);
        s.identityFactory = IIdentityFactory(identityFactoryAddress);
        s.checksDisabled = false;

        emit ERC3643EventsLib.ClaimTopicsRegistrySet(address(this));
        emit ERC3643EventsLib.TrustedIssuersRegistrySet(address(this));
        emit ERC3643EventsLib.IdentityStorageSet(identityStorageAddress);
        emit EventsLib.IdentityFactorySet(identityFactoryAddress);
        emit EventsLib.EligibilityChecksEnabled();

        __AccessManaged_init(accessManagerAddress);

        for (uint256 i = 0; i < initialTopics.length; i++) {
            _addClaimTopic(initialTopics[i]);
        }
        for (uint256 i = 0; i < issuers.length; i++) {
            _addTrustedIssuer(issuers[i], issuerClaims[i]);
        }
    }

    // ============================================================
    // IdentityRegistry
    // ============================================================

    /// @inheritdoc IERC3643IdentityRegistry
    function batchRegisterIdentity(
        address[] calldata userAddresses,
        IIdentity[] calldata identities,
        uint16[] calldata countries
    ) external override restricted {
        for (uint256 i = 0; i < userAddresses.length; i++) {
            _registerIdentity(userAddresses[i], identities[i], countries[i]);
        }
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function updateIdentity(address userAddress, IIdentity userIdentity) external override restricted {
        IIdentity oldIdentity = identity(userAddress);
        _getStorage().tokenIdentityStorage.modifyStoredIdentity(userAddress, userIdentity);
        emit ERC3643EventsLib.IdentityUpdated(oldIdentity, userIdentity);
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function updateCountry(address _userAddress, uint16 _country) external override restricted {
        _getStorage().tokenIdentityStorage.modifyStoredInvestorCountry(_userAddress, _country);
        emit ERC3643EventsLib.CountryUpdated(_userAddress, _country);
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function deleteIdentity(address _userAddress) external override restricted {
        IIdentity oldIdentity = identity(_userAddress);
        _getStorage().tokenIdentityStorage.removeIdentityFromStorage(_userAddress);
        emit ERC3643EventsLib.IdentityRemoved(_userAddress, oldIdentity);
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function setIdentityRegistryStorage(address _identityRegistryStorage) external override restricted {
        _getStorage().tokenIdentityStorage = IIdentityRegistryStorage(_identityRegistryStorage);
        emit ERC3643EventsLib.IdentityStorageSet(_identityRegistryStorage);
    }

    /// @inheritdoc ITREXRegistry
    function setIdentityFactory(address identityFactoryAddress) external override restricted {
        require(identityFactoryAddress != address(0), ErrorsLib.ZeroAddress());
        _getStorage().identityFactory = IIdentityFactory(identityFactoryAddress);
        emit EventsLib.IdentityFactorySet(identityFactoryAddress);
    }

    /// @inheritdoc ITREXRegistry
    function identityFactory() external view override returns (IIdentityFactory) {
        return _getStorage().identityFactory;
    }

    /// @inheritdoc IERC3643IdentityRegistry
    /// @dev DEPRECATED: this registry is its own ClaimTopicsRegistry; always reverts.
    function setClaimTopicsRegistry(address) external pure override {
        revert ErrorsLib.Deprecated();
    }

    /// @inheritdoc IERC3643IdentityRegistry
    /// @dev DEPRECATED: this registry is its own TrustedIssuersRegistry; always reverts.
    function setTrustedIssuersRegistry(address) external pure override {
        revert ErrorsLib.Deprecated();
    }

    /// @inheritdoc ITREXRegistry
    function disableEligibilityChecks() external override restricted {
        Storage storage s = _getStorage();
        require(!s.checksDisabled, ErrorsLib.EligibilityChecksDisabledAlready());
        s.checksDisabled = true;
        emit EventsLib.EligibilityChecksDisabled();
    }

    /// @inheritdoc ITREXRegistry
    function enableEligibilityChecks() external override restricted {
        Storage storage s = _getStorage();
        require(s.checksDisabled, ErrorsLib.EligibilityChecksEnabledAlready());
        s.checksDisabled = false;
        emit EventsLib.EligibilityChecksEnabled();
    }

    /// @inheritdoc IERC3643IdentityRegistry
    /// @dev The required topics depend on the identity type, read from the IdentityFactory record.
    ///  A non-empty override set for that type fully replaces the default `getClaimTopics()`. Type 0
    ///  (including identities the factory did not mint) or a type without an override uses the
    ///  default topics.
    function isVerified(address userAddress) external view override returns (bool) {
        Storage storage s = _getStorage();

        if (s.checksDisabled) return true;
        IIdentity userIdentity = identity(userAddress);
        if (address(userIdentity) == address(0)) return false;
        uint256[] memory requiredClaimTopics = _requiredClaimTopics(s, userIdentity);
        if (requiredClaimTopics.length == 0) {
            return true;
        }

        uint256 foundClaimTopic;
        uint256 scheme;
        address issuer;
        bytes memory sig;
        Structs.ClaimData memory data;
        uint256 claimTopic;
        for (claimTopic = 0; claimTopic < requiredClaimTopics.length; claimTopic++) {
            address[] memory trustedIssuersForTopic =
                s.claimTopicsToTrustedIssuers[requiredClaimTopics[claimTopic]].values();

            if (trustedIssuersForTopic.length == 0) return false;

            bytes32[] memory claimIds = new bytes32[](trustedIssuersForTopic.length);
            for (uint256 i = 0; i < trustedIssuersForTopic.length; i++) {
                claimIds[i] = keccak256(abi.encode(trustedIssuersForTopic[i], requiredClaimTopics[claimTopic]));
            }

            for (uint256 j = 0; j < claimIds.length; j++) {
                (foundClaimTopic, scheme, issuer, sig, data,) = userIdentity.getClaim(claimIds[j]);

                if (foundClaimTopic == requiredClaimTopics[claimTopic]) {
                    (bool success, bytes32 result,) = LowLevelCall.staticcallReturn64Bytes(
                        issuer,
                        abi.encodeCall(
                            IClaimIssuer.isClaimValid, (userIdentity, requiredClaimTopics[claimTopic], sig, data)
                        )
                    );

                    if (success && result != bytes32(0)) {
                        break;
                    } else if (j == (claimIds.length - 1)) {
                        return false;
                    }
                } else if (j == (claimIds.length - 1)) {
                    return false;
                }
            }
        }
        return true;
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function investorCountry(address _userAddress) external view override returns (uint16) {
        return _getStorage().tokenIdentityStorage.storedInvestorCountry(_userAddress);
    }

    /// @inheritdoc IERC3643IdentityRegistry
    /// @dev This registry is its own TrustedIssuersRegistry — returns `address(this)`.
    function issuersRegistry() external view override returns (IERC3643TrustedIssuersRegistry) {
        return IERC3643TrustedIssuersRegistry(address(this));
    }

    /// @inheritdoc IERC3643IdentityRegistry
    /// @dev This registry is its own ClaimTopicsRegistry — returns `address(this)`.
    function topicsRegistry() external view override returns (IERC3643ClaimTopicsRegistry) {
        return IERC3643ClaimTopicsRegistry(address(this));
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function identityStorage() external view override returns (IERC3643IdentityRegistryStorage) {
        return _getStorage().tokenIdentityStorage;
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function contains(address _userAddress) external view override returns (bool) {
        return address(identity(_userAddress)) != address(0);
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function registerIdentity(address _userAddress, IIdentity _identity, uint16 _country) public override restricted {
        _registerIdentity(_userAddress, _identity, _country);
    }

    function _registerIdentity(address userAddress, IIdentity userIdentity, uint16 country) internal {
        _getStorage().tokenIdentityStorage.addIdentityToStorage(userAddress, userIdentity, country);
        emit ERC3643EventsLib.IdentityRegistered(userAddress, userIdentity);
    }

    /// @inheritdoc IERC3643IdentityRegistry
    function identity(address _userAddress) public view override returns (IIdentity) {
        return _getStorage().tokenIdentityStorage.storedIdentity(_userAddress);
    }

    // ============================================================
    // TrustedIssuersRegistry
    // ============================================================

    /// @inheritdoc IERC3643TrustedIssuersRegistry
    function addTrustedIssuer(address _trustedIssuer, uint256[] calldata _claimTopics) external restricted {
        _addTrustedIssuer(_trustedIssuer, _claimTopics);
    }

    /// @inheritdoc IERC3643TrustedIssuersRegistry
    function removeTrustedIssuer(address _trustedIssuer) external restricted {
        require(_trustedIssuer != address(0), ErrorsLib.ZeroAddress());
        Storage storage s = _getStorage();
        require(s.trustedIssuers.remove(_trustedIssuer), ErrorsLib.NotATrustedIssuer());

        EnumerableSet.UintSet storage issuerTopics = s.trustedIssuerClaimTopics[_trustedIssuer];
        uint256[] memory claimTopics = issuerTopics.values();
        for (uint256 i = 0; i < claimTopics.length; i++) {
            s.claimTopicsToTrustedIssuers[claimTopics[i]].remove(_trustedIssuer);
        }
        issuerTopics.clear();

        emit ERC3643EventsLib.TrustedIssuerRemoved(_trustedIssuer);
    }

    /// @inheritdoc IERC3643TrustedIssuersRegistry
    /// @dev An empty `_claimTopics` reverts `ClaimTopicsCannotBeEmpty`; `removeTrustedIssuer` is the way to
    /// strip an issuer of every topic.
    function updateIssuerClaimTopics(address _trustedIssuer, uint256[] calldata _claimTopics) external restricted {
        require(_trustedIssuer != address(0), ErrorsLib.ZeroAddress());
        Storage storage s = _getStorage();
        require(s.trustedIssuers.contains(_trustedIssuer), ErrorsLib.NotATrustedIssuer());
        require(_claimTopics.length <= 15, ErrorsLib.MaxClaimTopicsReached(15));
        require(_claimTopics.length > 0, ErrorsLib.ClaimTopicsCannotBeEmpty());

        EnumerableSet.UintSet storage issuerTopics = s.trustedIssuerClaimTopics[_trustedIssuer];
        uint256[] memory oldTopics = issuerTopics.values();
        for (uint256 i = 0; i < oldTopics.length; i++) {
            s.claimTopicsToTrustedIssuers[oldTopics[i]].remove(_trustedIssuer);
        }
        issuerTopics.clear();

        for (uint256 i = 0; i < _claimTopics.length; i++) {
            if (issuerTopics.add(_claimTopics[i])) {
                s.claimTopicsToTrustedIssuers[_claimTopics[i]].add(_trustedIssuer);
            }
        }
        emit ERC3643EventsLib.ClaimTopicsUpdated(_trustedIssuer, _claimTopics);
    }

    /// @inheritdoc IERC3643TrustedIssuersRegistry
    function getTrustedIssuers() external view returns (address[] memory) {
        return _getStorage().trustedIssuers.values();
    }

    /// @inheritdoc IERC3643TrustedIssuersRegistry
    function getTrustedIssuersForClaimTopic(uint256 claimTopic) external view returns (address[] memory) {
        return _getStorage().claimTopicsToTrustedIssuers[claimTopic].values();
    }

    /// @inheritdoc IERC3643TrustedIssuersRegistry
    function isTrustedIssuer(address _issuer) external view returns (bool) {
        return _getStorage().trustedIssuers.contains(_issuer);
    }

    /// @inheritdoc IERC3643TrustedIssuersRegistry
    /// @dev Unlike the reference implementation this never reverts: an unknown issuer yields an empty array.
    function getTrustedIssuerClaimTopics(address _trustedIssuer) external view returns (uint256[] memory) {
        return _getStorage().trustedIssuerClaimTopics[_trustedIssuer].values();
    }

    /// @inheritdoc IERC3643TrustedIssuersRegistry
    function hasClaimTopic(address _issuer, uint256 _claimTopic) external view returns (bool) {
        return _getStorage().trustedIssuerClaimTopics[_issuer].contains(_claimTopic);
    }

    // ============================================================
    // ClaimTopicsRegistry
    // ============================================================

    /// @inheritdoc IERC3643ClaimTopicsRegistry
    /// @dev Changes to the default topics do NOT reach identity types holding an override: such types
    ///  keep verifying against their own set only. When a topic must apply to everyone, add it to every
    ///  registered override as well.
    function addClaimTopic(uint256 claimTopic) external restricted {
        _addClaimTopic(claimTopic);
    }

    /// @inheritdoc IERC3643ClaimTopicsRegistry
    function removeClaimTopic(uint256 claimTopic) external restricted {
        if (_getStorage().claimTopics.remove(claimTopic)) {
            emit ERC3643EventsLib.ClaimTopicRemoved(claimTopic);
        }
    }

    /// @inheritdoc IERC3643ClaimTopicsRegistry
    function getClaimTopics() external view returns (uint256[] memory) {
        return _getStorage().claimTopics.values();
    }

    /// @inheritdoc ITREXRegistry
    function addClaimTopicForIdentityType(uint256 identityType, uint256 claimTopic) external restricted {
        require(identityType != 0, ErrorsLib.InvalidIdentityType());
        EnumerableSet.UintSet storage typeTopics = _getStorage().claimTopicsByIdentityType[identityType];
        require(typeTopics.length() < 15, ErrorsLib.MaxClaimTopicsReached(15));
        require(typeTopics.add(claimTopic), ErrorsLib.ClaimTopicAlreadyExists());
        emit EventsLib.ClaimTopicAddedForIdentityType(identityType, claimTopic);
    }

    /// @inheritdoc ITREXRegistry
    /// @dev Removing an absent topic is a silent no-op, mirroring `removeClaimTopic`.
    function removeClaimTopicForIdentityType(uint256 identityType, uint256 claimTopic) external restricted {
        require(identityType != 0, ErrorsLib.InvalidIdentityType());
        if (_getStorage().claimTopicsByIdentityType[identityType].remove(claimTopic)) {
            emit EventsLib.ClaimTopicRemovedForIdentityType(identityType, claimTopic);
        }
    }

    /// @inheritdoc ITREXRegistry
    function getClaimTopicsForIdentityType(uint256 identityType) external view returns (uint256[] memory) {
        return _getStorage().claimTopicsByIdentityType[identityType].values();
    }

    // ============================================================
    // ERC-165
    // ============================================================

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ITREXRegistry).interfaceId
            || interfaceId == type(IERC3643IdentityRegistry).interfaceId
            || interfaceId == type(IERC3643TrustedIssuersRegistry).interfaceId
            || interfaceId == type(IERC3643ClaimTopicsRegistry).interfaceId || super.supportsInterface(interfaceId);
    }

    function _addTrustedIssuer(address _trustedIssuer, uint256[] memory _claimTopics) internal {
        require(_trustedIssuer != address(0), ErrorsLib.ZeroAddress());

        Storage storage s = _getStorage();
        require(!s.trustedIssuers.contains(_trustedIssuer), ErrorsLib.TrustedIssuerAlreadyExists());
        require(_claimTopics.length > 0, ErrorsLib.TrustedClaimTopicsCannotBeEmpty());
        require(_claimTopics.length <= 15, ErrorsLib.MaxClaimTopicsReached(15));
        require(s.trustedIssuers.length() < 50, ErrorsLib.MaxTrustedIssuersReached(50));
        s.trustedIssuers.add(_trustedIssuer);
        EnumerableSet.UintSet storage issuerTopics = s.trustedIssuerClaimTopics[_trustedIssuer];
        for (uint256 i = 0; i < _claimTopics.length; i++) {
            if (issuerTopics.add(_claimTopics[i])) {
                s.claimTopicsToTrustedIssuers[_claimTopics[i]].add(_trustedIssuer);
            }
        }

        // This event will re-emit eventual duplicated _claimTopics.
        // They won't be added to storage (.add ignores them) but will be emitted here regardless.
        emit ERC3643EventsLib.TrustedIssuerAdded(_trustedIssuer, _claimTopics);
    }

    /// @dev Resolves the claim topics an identity must satisfy. When the identity type has a
    ///  non-empty override set, that set is used. Otherwise the default `claimTopics` apply. The
    ///  type comes from the IdentityFactory record (`identityTypeOf`), never from the identity
    ///  contract, so a hostile identity cannot lie about its type or block the resolution.
    ///  Identities the factory did not mint have type 0 and use the default set.
    function _requiredClaimTopics(Storage storage s, IIdentity userIdentity) internal view returns (uint256[] memory) {
        uint256 identityType = s.identityFactory.identityTypeOf(address(userIdentity));
        if (identityType != 0) {
            uint256[] memory typeTopics = s.claimTopicsByIdentityType[identityType].values();
            if (typeTopics.length > 0) {
                return typeTopics;
            }
        }
        return s.claimTopics.values();
    }

    function _addClaimTopic(uint256 claimTopic) internal {
        Storage storage s = _getStorage();
        require(s.claimTopics.length() < 15, ErrorsLib.MaxClaimTopicsReached(15));

        require(s.claimTopics.add(claimTopic), ErrorsLib.ClaimTopicAlreadyExists());

        emit ERC3643EventsLib.ClaimTopicAdded(claimTopic);
    }

    function _getStorage() internal pure returns (Storage storage s) {
        assembly ("memory-safe") {
            s.slot := STORAGE_LOCATION
        }
    }

}
