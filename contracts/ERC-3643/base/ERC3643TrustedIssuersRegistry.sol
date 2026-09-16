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

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { ERC3643ErrorsLib } from "../ERC3643ErrorsLib.sol";
import { IERC3643TrustedIssuersRegistry } from "../IERC3643TrustedIssuersRegistry.sol";

/// @title ERC3643TrustedIssuersRegistry
/// @notice Standard-only base implementing the ERC-3643 Trusted Issuers Registry surface.
/// @dev Layer 2 of the ERC-3643 / T-REX split (see issue #65). Implements exactly the functions
///  `IERC3643TrustedIssuersRegistry` declares, over state held in its own ERC-7201 namespace. No T-REX
///  vocabulary, no reference to the T-REX layer.
///
///  The forward index `claimTopicsToTrustedIssuers` is maintained alongside the per-issuer topic set so
///  that `isVerified` can resolve the issuers for a topic in one read rather than scanning every issuer.
///  Both sides are written together in `_addTrustedIssuer`, `_removeTrustedIssuer` and
///  `_updateIssuerClaimTopics`, so they cannot drift.
///
///  Extension happens through the internal hooks; authorization is left to `_authorizeIssuersUpdate`
///  because the standard specifies no access-control model.
abstract contract ERC3643TrustedIssuersRegistry is IERC3643TrustedIssuersRegistry {

    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    /// @dev Caps borrowed from the reference implementation: they bound the work `isVerified` can be
    ///  made to do, which the token performs on every transfer.
    uint256 internal constant MAX_TRUSTED_ISSUERS = 50;

    uint256 internal constant MAX_ISSUER_CLAIM_TOPICS = 15;

    /// @custom:storage-location erc7201:erc3643.storage.TrustedIssuersRegistry
    struct ERC3643TrustedIssuersRegistryStorage {
        /// @dev All registered trusted issuer addresses.
        EnumerableSet.AddressSet trustedIssuers;

        /// @dev Topics each trusted issuer is trusted for.
        mapping(address issuer => EnumerableSet.UintSet) trustedIssuerClaimTopics;

        /// @dev Reverse index: issuers trusted for a given topic.
        mapping(uint256 topic => EnumerableSet.AddressSet) claimTopicsToTrustedIssuers;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.TrustedIssuersRegistry")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant TRUSTED_ISSUERS_REGISTRY_STORAGE_LOCATION =
        0x58a7ad278b8ace1eb0e9c3892258e09577cfdd8d75b47f8418fdf561b2770b00;

    /// @inheritdoc IERC3643TrustedIssuersRegistry
    function addTrustedIssuer(address _trustedIssuer, uint256[] calldata _claimTopics) external virtual {
        _authorizeIssuersUpdate();
        _addTrustedIssuer(_trustedIssuer, _claimTopics);
    }

    /// @inheritdoc IERC3643TrustedIssuersRegistry
    function removeTrustedIssuer(address _trustedIssuer) external virtual {
        _authorizeIssuersUpdate();
        _removeTrustedIssuer(_trustedIssuer);
    }

    /// @inheritdoc IERC3643TrustedIssuersRegistry
    function updateIssuerClaimTopics(address _trustedIssuer, uint256[] calldata _claimTopics) external virtual {
        _authorizeIssuersUpdate();
        _updateIssuerClaimTopics(_trustedIssuer, _claimTopics);
    }

    /// @inheritdoc IERC3643TrustedIssuersRegistry
    function getTrustedIssuers() external view virtual returns (address[] memory) {
        return _erc3643TrustedIssuersRegistryStorage().trustedIssuers.values();
    }

    /// @inheritdoc IERC3643TrustedIssuersRegistry
    function getTrustedIssuersForClaimTopic(uint256 claimTopic) external view virtual returns (address[] memory) {
        return _trustedIssuersForClaimTopic(claimTopic);
    }

    /// @inheritdoc IERC3643TrustedIssuersRegistry
    function isTrustedIssuer(address _issuer) external view virtual returns (bool) {
        return _erc3643TrustedIssuersRegistryStorage().trustedIssuers.contains(_issuer);
    }

    /// @inheritdoc IERC3643TrustedIssuersRegistry
    /// @dev Unlike the reference implementation this never reverts: an unknown issuer yields an empty array.
    function getTrustedIssuerClaimTopics(address _trustedIssuer) external view virtual returns (uint256[] memory) {
        return _erc3643TrustedIssuersRegistryStorage().trustedIssuerClaimTopics[_trustedIssuer].values();
    }

    /// @inheritdoc IERC3643TrustedIssuersRegistry
    function hasClaimTopic(address _issuer, uint256 _claimTopic) external view virtual returns (bool) {
        return _erc3643TrustedIssuersRegistryStorage().trustedIssuerClaimTopics[_issuer].contains(_claimTopic);
    }

    /// @dev Authorization hook for every state-changing function of this base. Left abstract on purpose:
    ///  the standard specifies no access model.
    function _authorizeIssuersUpdate() internal virtual;

    /// @dev Registers a trusted issuer for a set of claim topics, maintaining the reverse index.
    function _addTrustedIssuer(address trustedIssuer, uint256[] memory claimTopics) internal virtual {
        require(trustedIssuer != address(0), ERC3643ErrorsLib.ZeroAddress());

        ERC3643TrustedIssuersRegistryStorage storage s = _erc3643TrustedIssuersRegistryStorage();
        require(!s.trustedIssuers.contains(trustedIssuer), ERC3643ErrorsLib.TrustedIssuerAlreadyExists());
        require(claimTopics.length > 0, ERC3643ErrorsLib.TrustedClaimTopicsCannotBeEmpty());
        require(
            claimTopics.length <= MAX_ISSUER_CLAIM_TOPICS,
            ERC3643ErrorsLib.MaxClaimTopicsReached(MAX_ISSUER_CLAIM_TOPICS)
        );
        require(
            s.trustedIssuers.length() < MAX_TRUSTED_ISSUERS,
            ERC3643ErrorsLib.MaxTrustedIssuersReached(MAX_TRUSTED_ISSUERS)
        );

        s.trustedIssuers.add(trustedIssuer);
        EnumerableSet.UintSet storage issuerTopics = s.trustedIssuerClaimTopics[trustedIssuer];
        for (uint256 i = 0; i < claimTopics.length; i++) {
            if (issuerTopics.add(claimTopics[i])) {
                s.claimTopicsToTrustedIssuers[claimTopics[i]].add(trustedIssuer);
            }
        }

        // This event re-emits any duplicated topics. They are not added to storage (`.add` ignores them)
        // but are emitted here regardless, matching the reference implementation.
        emit TrustedIssuerAdded(trustedIssuer, claimTopics);
    }

    /// @dev Removes a trusted issuer and every reverse-index entry pointing at it.
    function _removeTrustedIssuer(address trustedIssuer) internal virtual {
        require(trustedIssuer != address(0), ERC3643ErrorsLib.ZeroAddress());
        ERC3643TrustedIssuersRegistryStorage storage s = _erc3643TrustedIssuersRegistryStorage();
        require(s.trustedIssuers.remove(trustedIssuer), ERC3643ErrorsLib.NotATrustedIssuer());

        EnumerableSet.UintSet storage issuerTopics = s.trustedIssuerClaimTopics[trustedIssuer];
        uint256[] memory claimTopics = issuerTopics.values();
        for (uint256 i = 0; i < claimTopics.length; i++) {
            s.claimTopicsToTrustedIssuers[claimTopics[i]].remove(trustedIssuer);
        }
        issuerTopics.clear();

        emit TrustedIssuerRemoved(trustedIssuer);
    }

    /// @dev Replaces the topics an issuer is trusted for, rebuilding its reverse-index entries.
    ///  An empty `claimTopics` reverts; `_removeTrustedIssuer` is the way to strip an issuer of every topic.
    function _updateIssuerClaimTopics(address trustedIssuer, uint256[] memory claimTopics) internal virtual {
        require(trustedIssuer != address(0), ERC3643ErrorsLib.ZeroAddress());
        ERC3643TrustedIssuersRegistryStorage storage s = _erc3643TrustedIssuersRegistryStorage();
        require(s.trustedIssuers.contains(trustedIssuer), ERC3643ErrorsLib.NotATrustedIssuer());
        require(
            claimTopics.length <= MAX_ISSUER_CLAIM_TOPICS,
            ERC3643ErrorsLib.MaxClaimTopicsReached(MAX_ISSUER_CLAIM_TOPICS)
        );
        require(claimTopics.length > 0, ERC3643ErrorsLib.TrustedClaimTopicsCannotBeEmpty());

        EnumerableSet.UintSet storage issuerTopics = s.trustedIssuerClaimTopics[trustedIssuer];
        uint256[] memory oldTopics = issuerTopics.values();
        for (uint256 i = 0; i < oldTopics.length; i++) {
            s.claimTopicsToTrustedIssuers[oldTopics[i]].remove(trustedIssuer);
        }
        issuerTopics.clear();

        for (uint256 i = 0; i < claimTopics.length; i++) {
            if (issuerTopics.add(claimTopics[i])) {
                s.claimTopicsToTrustedIssuers[claimTopics[i]].add(trustedIssuer);
            }
        }
        emit ClaimTopicsUpdated(trustedIssuer, claimTopics);
    }

    /// @dev Issuers trusted for `claimTopic`. Used by identity verification to avoid scanning all issuers.
    function _trustedIssuersForClaimTopic(uint256 claimTopic) internal view virtual returns (address[] memory) {
        return _erc3643TrustedIssuersRegistryStorage().claimTopicsToTrustedIssuers[claimTopic].values();
    }

    function _erc3643TrustedIssuersRegistryStorage()
        internal
        pure
        returns (ERC3643TrustedIssuersRegistryStorage storage s)
    {
        assembly ("memory-safe") {
            s.slot := TRUSTED_ISSUERS_REGISTRY_STORAGE_LOCATION
        }
    }

}
