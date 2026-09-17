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

import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { IERC3643ClaimTopicsRegistry } from "../../ERC-3643/IERC3643ClaimTopicsRegistry.sol";
import { IERC3643IdentityRegistry } from "../../ERC-3643/IERC3643IdentityRegistry.sol";
import { IERC3643IdentityRegistryStorage } from "../../ERC-3643/IERC3643IdentityRegistryStorage.sol";
import { IERC3643TrustedIssuersRegistry } from "../../ERC-3643/IERC3643TrustedIssuersRegistry.sol";
import { ERC3643ClaimTopicsRegistry } from "../../ERC-3643/base/ERC3643ClaimTopicsRegistry.sol";
import { ERC3643IdentityRegistry } from "../../ERC-3643/base/ERC3643IdentityRegistry.sol";
import { ERC3643TrustedIssuersRegistry } from "../../ERC-3643/base/ERC3643TrustedIssuersRegistry.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { AccessManagedOwnableUpgradeable } from "../../utils/AccessManagedOwnableUpgradeable.sol";
import { ITREXRegistry } from "../interface/ITREXRegistry.sol";

/// @title TREXRegistry
/// @dev The identity, trusted-issuers and claim-topics registries at one address. Each base keeps its
/// own namespace and stays separately replaceable; `_issuersRegistry` and `_topicsRegistry` are
/// overridden to return `address(this)`, which is the only seam joining them.
/// T-REX additions: per-identity-type claim topics, the eligibility kill switch, the ONCHAINID
/// IdentityFactory, AccessManager authorization.
contract TREXRegistry is
    ITREXRegistry,
    ERC3643IdentityRegistry,
    ERC3643TrustedIssuersRegistry,
    ERC3643ClaimTopicsRegistry,
    AccessManagedOwnableUpgradeable
{

    using EnumerableSet for EnumerableSet.UintSet;

    /// @custom:storage-location erc7201:erc3643.storage.TREXEligibility
    /// @dev A new namespace, not the old `erc3643.storage.TREXRegistry`: five fields moved to the
    ///  standard bases, so reusing the old one would leave `checksDisabled` reading the low byte of the
    ///  old storage address and silently verify everyone. Migration in docs/erc3643-oz-swap.md.
    struct Storage {
        /// @dev When true, `isVerified` short-circuits to true for every address.
        bool checksDisabled;

        /// @dev Per-identity-type claim topic overrides; a non-empty set fully replaces the default
        ///  claim topics for identities of that type inside `isVerified`.
        mapping(uint256 identityType => EnumerableSet.UintSet claimTopics) claimTopicsByIdentityType;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.TREXEligibility")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant STORAGE_LOCATION = 0xe60ad881f2e5dd9ad5e5fabfb6687133de1b3b6f4c77607e9031b076e00b7500;

    /// @dev T-REX caps inherited from v4; they bound the work `isVerified` does on every transfer.
    ///  Both topic caps are 15, as in v4.
    uint256 private constant MAX_CLAIM_TOPICS = 15;
    uint256 private constant MAX_TRUSTED_ISSUERS = 50;

    /// @dev ONCHAINID IdentityFactory used by `isVerified` to read an identity's type. The factory
    ///  records the type once at minting and never updates it, so it is a safer source than asking
    ///  the identity contract itself. Baked into the implementation so it cannot be repointed at
    ///  runtime; changing it takes a new implementation published through the beacon.
    IIdentityFactory private immutable _IDENTITY_FACTORY;

    /// @param identityFactoryAddress the ONCHAINID IdentityFactory whose type record backs the
    ///        per-type claim topic resolution
    constructor(address identityFactoryAddress) {
        require(identityFactoryAddress != address(0), ErrorsLib.ZeroAddress());
        _IDENTITY_FACTORY = IIdentityFactory(identityFactoryAddress);
        _disableInitializers();
    }

    /// @notice Initializes the contract
    /// @param identityStorageAddress the address of the (external) identity registry storage
    /// @param accessManagerAddress the address of the access manager
    /// @param initialTopics the claim topics required at deployment
    /// @param issuers the trusted issuers to register at deployment
    /// @param issuerClaims the claim topics each entry of `issuers` is trusted for
    function init(
        address identityStorageAddress,
        address accessManagerAddress,
        uint256[] memory initialTopics,
        address[] memory issuers,
        uint256[][] memory issuerClaims
    ) external initializer {
        require(identityStorageAddress != address(0) && accessManagerAddress != address(0), ErrorsLib.ZeroAddress());
        require(issuers.length == issuerClaims.length, ErrorsLib.InvalidClaimPattern());

        _setIdentityRegistryStorage(identityStorageAddress);

        // This registry is its own claim topics and trusted issuers registry; announce that explicitly
        // so indexers see the same three "registry set" events a three-contract deployment emits.
        emit ClaimTopicsRegistrySet(address(this));
        emit TrustedIssuersRegistrySet(address(this));
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
    /// @dev DEPRECATED: this registry is its own ClaimTopicsRegistry; always reverts. Reverted the same
    ///  way before the split; see docs/erc3643-oz-swap.md for why this is the one sanctioned exception.
    function setClaimTopicsRegistry(address) external pure override(ERC3643IdentityRegistry, IERC3643IdentityRegistry) {
        revert ErrorsLib.Deprecated();
    }

    /// @inheritdoc IERC3643IdentityRegistry
    /// @dev DEPRECATED: this registry is its own TrustedIssuersRegistry; always reverts.
    function setTrustedIssuersRegistry(address)
        external
        pure
        override(ERC3643IdentityRegistry, IERC3643IdentityRegistry)
    {
        revert ErrorsLib.Deprecated();
    }

    /// @inheritdoc ITREXRegistry
    function identityFactory() external view override returns (IIdentityFactory) {
        return _IDENTITY_FACTORY;
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

    // ============================================================
    // ClaimTopicsRegistry — per-identity-type overrides (#25)
    // ============================================================

    /// @inheritdoc ITREXRegistry
    function addClaimTopicForIdentityType(uint256 identityType, uint256 claimTopic) external restricted {
        require(identityType != 0, ErrorsLib.InvalidIdentityType());
        EnumerableSet.UintSet storage typeTopics = _getStorage().claimTopicsByIdentityType[identityType];
        require(typeTopics.length() < MAX_CLAIM_TOPICS, ErrorsLib.MaxClaimTopicsReached(MAX_CLAIM_TOPICS));
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

    // ============================================================
    // Layer-2 hook implementations
    // ============================================================

    /// @dev This registry *is* its own trusted issuers registry. Overriding the resolution hook rather
    ///  than storing an address is what makes the consolidation a composition: the identity base still
    ///  asks "which issuers are trusted for this topic?" and the trusted-issuers base still answers,
    ///  they simply share an address.
    function _issuersRegistry() internal view override returns (IERC3643TrustedIssuersRegistry) {
        return IERC3643TrustedIssuersRegistry(address(this));
    }

    /// @dev This registry is its own claim topics registry. See the note on `_issuersRegistry`.
    function _topicsRegistry() internal view override returns (IERC3643ClaimTopicsRegistry) {
        return IERC3643ClaimTopicsRegistry(address(this));
    }

    /// @dev Reads the trusted issuers for a topic from this contract's own trusted-issuers state,
    ///  skipping the external call the default hook would make to itself.
    function _trustedIssuersForTopic(uint256 claimTopic) internal view override returns (address[] memory) {
        return _trustedIssuersForClaimTopic(claimTopic);
    }

    /// @dev Resolves the claim topics an identity must satisfy. When the identity type has a
    ///  non-empty override set, that set is used. Otherwise the default topics apply. The type comes
    ///  from the IdentityFactory record (`identityTypeOf`), never from the identity contract, so a
    ///  hostile identity cannot lie about its type or block the resolution. Identities the factory did
    ///  not mint have type 0 and use the default set.
    function _requiredClaimTopics(IIdentity userIdentity) internal view override returns (uint256[] memory) {
        uint256 identityType = _IDENTITY_FACTORY.identityTypeOf(address(userIdentity));
        if (identityType != 0) {
            uint256[] memory typeTopics = _getStorage().claimTopicsByIdentityType[identityType].values();
            if (typeTopics.length > 0) {
                return typeTopics;
            }
        }
        return _getClaimTopics();
    }

    /// @dev The eligibility kill switch short-circuits verification for every address.
    function _isVerified(address userAddress) internal view override returns (bool) {
        if (_getStorage().checksDisabled) return true;
        return super._isVerified(userAddress);
    }

    function _maxClaimTopics() internal pure override returns (uint256) {
        return MAX_CLAIM_TOPICS;
    }

    function _maxTrustedIssuers() internal pure override returns (uint256) {
        return MAX_TRUSTED_ISSUERS;
    }

    function _maxIssuerClaimTopics() internal pure override returns (uint256) {
        return MAX_CLAIM_TOPICS;
    }

    function _authorizeIdentityUpdate(bytes4 selector) internal override {
        _checkCanCallSelector(selector);
    }

    /// @dev T-REX authorization for `setIdentityRegistryStorage`. A storage that cannot answer identity
    ///  reads halts the token, which calls `isVerified` on every transfer, so the target is checked for
    ///  interface support and for a shared authority. `onlySharedAuthority` is a misconfiguration guard
    ///  only: `authority()` is spoofable.
    function _authorizeRegistryUpdate(address newRegistry) internal override {
        _checkCanCall(_msgSender(), msg.data);
        _checkSharedAuthority(newRegistry);
        require(
            ERC165Checker.supportsInterface(newRegistry, type(IERC3643IdentityRegistryStorage).interfaceId),
            ErrorsLib.InvalidIdentityRegistryStorage()
        );
    }

    /// @dev T-REX authorization for the trusted-issuer functions.
    function _authorizeIssuersUpdate() internal override {
        _checkCanCall(_msgSender(), msg.data);
    }

    /// @dev T-REX authorization for the claim-topic functions.
    function _authorizeClaimTopicsUpdate() internal override {
        _checkCanCall(_msgSender(), msg.data);
    }

    function _getStorage() internal pure returns (Storage storage s) {
        assembly ("memory-safe") {
            s.slot := STORAGE_LOCATION
        }
    }

}
