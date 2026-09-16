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
import { IERC3643ClaimTopicsRegistry } from "../IERC3643ClaimTopicsRegistry.sol";

/// @title ERC3643ClaimTopicsRegistry
/// @notice Standard-only base implementing the ERC-3643 Claim Topics Registry surface.
/// @dev Layer 2 of the ERC-3643 / T-REX split (see issue #65). This contract implements exactly the
///  functions `IERC3643ClaimTopicsRegistry` declares and holds only the state the standard needs, in its
///  own ERC-7201 namespace. It carries no T-REX vocabulary and refers to nothing in the T-REX layer.
///
///  Extension happens through the internal hooks, never by overriding the external functions:
///  derived contracts add behavior around `_addClaimTopic` / `_removeClaimTopic`, and enforce their own
///  authorization in `_authorizeClaimTopicsUpdate`. This is the seam that lets the whole base be replaced
///  by OpenZeppelin's implementation when it ships, without touching the extension layer.
///
///  This base is authorization-agnostic: it declares `_authorizeClaimTopicsUpdate` and leaves the policy
///  to the derived contract, because the standard does not specify an access-control model.
abstract contract ERC3643ClaimTopicsRegistry is IERC3643ClaimTopicsRegistry {

    using EnumerableSet for EnumerableSet.UintSet;

    /// @dev The standard caps the topic list so that `isVerified` cannot be made to run out of gas.
    uint256 internal constant MAX_CLAIM_TOPICS = 15;

    /// @custom:storage-location erc7201:erc3643.storage.ClaimTopicsRegistry
    struct ERC3643ClaimTopicsRegistryStorage {
        EnumerableSet.UintSet claimTopics;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.ClaimTopicsRegistry")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CLAIM_TOPICS_REGISTRY_STORAGE_LOCATION =
        0xf733c3a0e1c477ac68147f80e659cc05e7e57f7c461b47d14f8d9811f4c72700;

    /// @inheritdoc IERC3643ClaimTopicsRegistry
    function addClaimTopic(uint256 _claimTopic) external virtual {
        _authorizeClaimTopicsUpdate();
        _addClaimTopic(_claimTopic);
    }

    /// @inheritdoc IERC3643ClaimTopicsRegistry
    function removeClaimTopic(uint256 _claimTopic) external virtual {
        _authorizeClaimTopicsUpdate();
        _removeClaimTopic(_claimTopic);
    }

    /// @inheritdoc IERC3643ClaimTopicsRegistry
    function getClaimTopics() external view virtual returns (uint256[] memory) {
        return _getClaimTopics();
    }

    /// @dev Authorization hook for every state-changing function of this base. Reverts when the caller
    ///  may not update the claim topics. Left abstract on purpose: the standard specifies no access model.
    function _authorizeClaimTopicsUpdate() internal virtual;

    /// @dev Adds a required claim topic. Reverts on duplicates and past the cap.
    function _addClaimTopic(uint256 claimTopic) internal virtual {
        EnumerableSet.UintSet storage topics = _erc3643ClaimTopicsRegistryStorage().claimTopics;
        require(topics.length() < MAX_CLAIM_TOPICS, ERC3643ErrorsLib.MaxClaimTopicsReached(MAX_CLAIM_TOPICS));
        require(topics.add(claimTopic), ERC3643ErrorsLib.ClaimTopicAlreadyExists());
        emit ClaimTopicAdded(claimTopic);
    }

    /// @dev Removes a required claim topic. Removing an absent topic is a silent no-op.
    function _removeClaimTopic(uint256 claimTopic) internal virtual {
        if (_erc3643ClaimTopicsRegistryStorage().claimTopics.remove(claimTopic)) {
            emit ClaimTopicRemoved(claimTopic);
        }
    }

    /// @dev Reads the required claim topics. Separate from the external getter so derived contracts can
    ///  consult the standard set without re-entering their own overridden view.
    function _getClaimTopics() internal view virtual returns (uint256[] memory) {
        return _erc3643ClaimTopicsRegistryStorage().claimTopics.values();
    }

    /// @dev Number of required claim topics, for derived contracts enforcing their own caps.
    function _claimTopicsLength() internal view returns (uint256) {
        return _erc3643ClaimTopicsRegistryStorage().claimTopics.length();
    }

    function _erc3643ClaimTopicsRegistryStorage() internal pure returns (ERC3643ClaimTopicsRegistryStorage storage s) {
        assembly ("memory-safe") {
            s.slot := CLAIM_TOPICS_REGISTRY_STORAGE_LOCATION
        }
    }

}
