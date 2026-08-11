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
import { IERC3643ClaimTopicsRegistry } from "../../ERC-3643/IERC3643ClaimTopicsRegistry.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { AccessManagedOwnableUpgradeable } from "../../utils/AccessManagedOwnableUpgradeable.sol";
import { IClaimTopicsRegistry } from "../interface/IClaimTopicsRegistry.sol";

contract ClaimTopicsRegistry is IClaimTopicsRegistry, AccessManagedOwnableUpgradeable {

    using EnumerableSet for EnumerableSet.UintSet;

    /// @custom:storage-location erc7201:ERC3643.storage.ClaimTopicsRegistry
    struct Storage {
        EnumerableSet.UintSet claimTopics;
        mapping(uint256 identityType => EnumerableSet.UintSet claimTopics) claimTopicsByIdentityType;
    }

    // keccak256(abi.encode(uint256(keccak256("ERC3643.storage.ClaimTopicsRegistry")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant STORAGE_LOCATION = 0xeb77843660c963beb5d27db8816b70a285e2678d36793e5743f8650e153ee600;

    constructor() {
        _disableInitializers();
    }

    function init(address accessManagerAddress, uint256[] calldata initialTopics) external initializer {
        require(accessManagerAddress != address(0), ErrorsLib.ZeroAddress());
        __AccessManaged_init(accessManagerAddress);

        for (uint256 i = 0; i < initialTopics.length; i++) {
            _addClaimTopic(initialTopics[i]);
        }
    }

    /**
     *  @dev See {IClaimTopicsRegistry-addClaimTopic}.
     */
    function addClaimTopic(uint256 claimTopic) external restricted {
        _addClaimTopic(claimTopic);
    }

    /**
     *  @dev See {IClaimTopicsRegistry-removeClaimTopic}.
     */
    function removeClaimTopic(uint256 claimTopic) external restricted {
        if (_getStorage().claimTopics.remove(claimTopic)) {
            emit ERC3643EventsLib.ClaimTopicRemoved(claimTopic);
        }
    }

    /**
     *  @dev See {IClaimTopicsRegistry-addClaimTopicForIdentityType}.
     */
    function addClaimTopicForIdentityType(uint256 identityType, uint256 claimTopic) external restricted {
        require(identityType != 0, ErrorsLib.InvalidIdentityType());

        EnumerableSet.UintSet storage typeTopics = _getStorage().claimTopicsByIdentityType[identityType];
        require(typeTopics.length() < 15, ErrorsLib.MaxClaimTopicsReached(15));
        require(typeTopics.add(claimTopic), ErrorsLib.ClaimTopicAlreadyExists());

        emit EventsLib.ClaimTopicAddedForIdentityType(identityType, claimTopic);
    }

    /**
     *  @dev See {IClaimTopicsRegistry-removeClaimTopicForIdentityType}.
     */
    function removeClaimTopicForIdentityType(uint256 identityType, uint256 claimTopic) external restricted {
        require(identityType != 0, ErrorsLib.InvalidIdentityType());

        if (_getStorage().claimTopicsByIdentityType[identityType].remove(claimTopic)) {
            emit EventsLib.ClaimTopicRemovedForIdentityType(identityType, claimTopic);
        }
    }

    /**
     *  @dev See {IClaimTopicsRegistry-getClaimTopics}.
     */
    function getClaimTopics() external view returns (uint256[] memory) {
        return _getStorage().claimTopics.values();
    }

    /**
     *  @dev See {IClaimTopicsRegistry-getClaimTopicsForIdentityType}.
     */
    function getClaimTopicsForIdentityType(uint256 identityType) external view returns (uint256[] memory) {
        return _getStorage().claimTopicsByIdentityType[identityType].values();
    }

    /**
     *  @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IClaimTopicsRegistry).interfaceId
            || interfaceId == type(IERC3643ClaimTopicsRegistry).interfaceId || super.supportsInterface(interfaceId);
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
