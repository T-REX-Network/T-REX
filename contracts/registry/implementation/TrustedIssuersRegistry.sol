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

import { ERC3643EventsLib } from "../../ERC-3643/ERC3643EventsLib.sol";
import { IERC3643TrustedIssuersRegistry } from "../../ERC-3643/IERC3643TrustedIssuersRegistry.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { AccessManagedOwnableUpgradeable } from "../../utils/AccessManagedOwnableUpgradeable.sol";
import { ITrustedIssuersRegistry } from "../interface/ITrustedIssuersRegistry.sol";

contract TrustedIssuersRegistry is ITrustedIssuersRegistry, AccessManagedOwnableUpgradeable {

    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    /// @custom:storage-location erc7201:ERC3643.storage.TrustedIssuersRegistry
    struct Storage {
        /// @dev Set containing all TrustedIssuers identity contract addresses.
        EnumerableSet.AddressSet trustedIssuers;

        /// @dev Mapping between a trusted issuer address and its corresponding claimTopics.
        mapping(address issuer => EnumerableSet.UintSet) trustedIssuerClaimTopics;

        /// @dev Mapping between a claim topic and the allowed trusted issuers for it.
        mapping(uint256 topic => EnumerableSet.AddressSet) claimTopicsToTrustedIssuers;
    }

    // keccak256(abi.encode(uint256(keccak256("ERC3643.storage.TrustedIssuersRegistry")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant STORAGE_LOCATION = 0xcf1a470b7a594e056f36cedab0ef91f3f14bce049596c7dfdd4c7c9a318d5000;

    constructor() {
        _disableInitializers();
    }

    function init(address accessManagerAddress, address[] calldata issuers, uint256[][] calldata issuerClaims)
        external
        initializer
    {
        require(accessManagerAddress != address(0), ErrorsLib.ZeroAddress());
        require(issuers.length == issuerClaims.length, ErrorsLib.InvalidClaimPattern());

        __AccessManaged_init(accessManagerAddress);

        for (uint256 i = 0; i < issuers.length; i++) {
            _addTrustedIssuer(issuers[i], issuerClaims[i]);
        }
    }

    /**
     *  @dev See {ITrustedIssuersRegistry-addTrustedIssuer}.
     */
    function addTrustedIssuer(address _trustedIssuer, uint256[] calldata _claimTopics) external restricted {
        _addTrustedIssuer(_trustedIssuer, _claimTopics);
    }

    /**
     *  @dev See {ITrustedIssuersRegistry-removeTrustedIssuer}.
     */
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

    /**
     *  @dev See {ITrustedIssuersRegistry-updateIssuerClaimTopics}.
     */
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
            issuerTopics.add(_claimTopics[i]);
            s.claimTopicsToTrustedIssuers[_claimTopics[i]].add(_trustedIssuer);
        }
        emit ERC3643EventsLib.ClaimTopicsUpdated(_trustedIssuer, _claimTopics);
    }

    /**
     *  @dev See {ITrustedIssuersRegistry-getTrustedIssuers}.
     */
    function getTrustedIssuers() external view returns (address[] memory) {
        return _getStorage().trustedIssuers.values();
    }

    /**
     *  @dev See {ITrustedIssuersRegistry-getTrustedIssuersForClaimTopic}.
     */
    function getTrustedIssuersForClaimTopic(uint256 claimTopic) external view returns (address[] memory) {
        return _getStorage().claimTopicsToTrustedIssuers[claimTopic].values();
    }

    /**
     *  @dev See {ITrustedIssuersRegistry-isTrustedIssuer}.
     */
    function isTrustedIssuer(address _issuer) external view returns (bool) {
        return _getStorage().trustedIssuers.contains(_issuer);
    }

    /**
     *  @dev See {ITrustedIssuersRegistry-getTrustedIssuerClaimTopics}.
     */
    function getTrustedIssuerClaimTopics(address _trustedIssuer) external view returns (uint256[] memory) {
        Storage storage s = _getStorage();
        require(s.trustedIssuers.contains(_trustedIssuer), ErrorsLib.TrustedIssuerDoesNotExist());
        return s.trustedIssuerClaimTopics[_trustedIssuer].values();
    }

    /**
     *  @dev See {ITrustedIssuersRegistry-hasClaimTopic}.
     */
    function hasClaimTopic(address _issuer, uint256 _claimTopic) external view returns (bool) {
        return _getStorage().trustedIssuerClaimTopics[_issuer].contains(_claimTopic);
    }

    /**
     *  @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC3643TrustedIssuersRegistry).interfaceId || super.supportsInterface(interfaceId);
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
            issuerTopics.add(_claimTopics[i]);
            s.claimTopicsToTrustedIssuers[_claimTopics[i]].add(_trustedIssuer);
        }

        // This event will re-emit eventual duplicated _claimTopics.
        // They won't be added to storage (.add ignores them) but will be emitted here regardless.
        emit ERC3643EventsLib.TrustedIssuerAdded(_trustedIssuer, _claimTopics);
    }

    function _getStorage() internal pure returns (Storage storage s) {
        assembly ("memory-safe") {
            s.slot := STORAGE_LOCATION
        }
    }

}
