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
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { ERC3643EventsLib } from "../../ERC-3643/ERC3643EventsLib.sol";
import { IERC3643TrustedIssuersRegistry } from "../../ERC-3643/IERC3643TrustedIssuersRegistry.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { IERC173 } from "../../roles/IERC173.sol";
import { ITrustedIssuersRegistry } from "../interface/ITrustedIssuersRegistry.sol";

contract TrustedIssuersRegistry is ITrustedIssuersRegistry, Ownable2StepUpgradeable, IERC165 {

    using EnumerableSet for EnumerableSet.AddressSet;

    /// @custom:storage-location erc7201:ERC3643.storage.TrustedIssuersRegistry
    struct Storage {
        /// @dev Set containing all TrustedIssuers identity contract addresses.
        EnumerableSet.AddressSet trustedIssuers;

        /// @dev Mapping between a trusted issuer address and its corresponding claimTopics.
        mapping(address issuer => uint256[]) trustedIssuerClaimTopics;

        /// @dev Mapping between a claim topic and the allowed trusted issuers for it.
        mapping(uint256 claimTopic => IClaimIssuer[]) claimTopicsToTrustedIssuers;
    }

    // keccak256(abi.encode(uint256(keccak256("ERC3643.storage.TrustedIssuersRegistry")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant STORAGE_LOCATION = 0xcf1a470b7a594e056f36cedab0ef91f3f14bce049596c7dfdd4c7c9a318d5000;

    constructor() {
        _disableInitializers();
    }

    /// Functions

    function init(address _owner, address[] calldata _issuers, uint256[][] calldata _issuerClaims)
        external
        initializer
    {
        require(_issuers.length == _issuerClaims.length, ErrorsLib.InvalidClaimPattern());
        require(_issuers.length <= 5, ErrorsLib.MaxClaimIssuersReached(5));
        __Ownable_init(_owner);
        for (uint256 i = 0; i < _issuers.length; i++) {
            _addTrustedIssuer(IClaimIssuer(_issuers[i]), _issuerClaims[i]);
        }
    }

    /**
     *  @dev See {ITrustedIssuersRegistry-addTrustedIssuer}.
     */
    function addTrustedIssuer(IClaimIssuer _trustedIssuer, uint256[] calldata _claimTopics)
        external
        override
        onlyOwner
    {
        _addTrustedIssuer(_trustedIssuer, _claimTopics);
    }

    /**
     *  @dev See {ITrustedIssuersRegistry-removeTrustedIssuer}.
     */
    function removeTrustedIssuer(IClaimIssuer _trustedIssuer) external override onlyOwner {
        require(address(_trustedIssuer) != address(0), ErrorsLib.ZeroAddress());
        Storage storage s = _getStorage();
        require(s.trustedIssuers.contains(address(_trustedIssuer)), ErrorsLib.NotATrustedIssuer());
        s.trustedIssuers.remove(address(_trustedIssuer));

        uint256[] storage claimTopics = s.trustedIssuerClaimTopics[address(_trustedIssuer)];

        for (uint256 claimTopicIndex = 0; claimTopicIndex < claimTopics.length; claimTopicIndex++) {
            uint256 claimTopic = claimTopics[claimTopicIndex];
            uint256 topicsLength = s.claimTopicsToTrustedIssuers[claimTopic].length;
            for (uint256 i = 0; i < topicsLength; i++) {
                if (s.claimTopicsToTrustedIssuers[claimTopic][i] == _trustedIssuer) {
                    s.claimTopicsToTrustedIssuers[claimTopic][i] =
                        s.claimTopicsToTrustedIssuers[claimTopic][topicsLength - 1];
                    s.claimTopicsToTrustedIssuers[claimTopic].pop();
                    break;
                }
            }
        }
        delete s.trustedIssuerClaimTopics[address(_trustedIssuer)];
        emit ERC3643EventsLib.TrustedIssuerRemoved(_trustedIssuer);
    }

    /**
     *  @dev See {ITrustedIssuersRegistry-updateIssuerClaimTopics}.
     */
    function updateIssuerClaimTopics(IClaimIssuer _trustedIssuer, uint256[] calldata _claimTopics)
        external
        override
        onlyOwner
    {
        require(address(_trustedIssuer) != address(0), ErrorsLib.ZeroAddress());
        Storage storage s = _getStorage();
        require(s.trustedIssuers.contains(address(_trustedIssuer)), ErrorsLib.NotATrustedIssuer());
        require(_claimTopics.length <= 15, ErrorsLib.MaxClaimTopcisReached(15));
        require(_claimTopics.length > 0, ErrorsLib.ClaimTopicsCannotBeEmpty());

        uint256[] storage claimTopics = s.trustedIssuerClaimTopics[address(_trustedIssuer)];
        for (uint256 i = 0; i < claimTopics.length; i++) {
            uint256 claimTopic = claimTopics[i];
            uint256 topicsLength = s.claimTopicsToTrustedIssuers[claimTopic].length;
            for (uint256 j = 0; j < topicsLength; j++) {
                if (s.claimTopicsToTrustedIssuers[claimTopic][j] == _trustedIssuer) {
                    s.claimTopicsToTrustedIssuers[claimTopic][j] =
                        s.claimTopicsToTrustedIssuers[claimTopic][topicsLength - 1];
                    s.claimTopicsToTrustedIssuers[claimTopic].pop();
                    break;
                }
            }
        }
        s.trustedIssuerClaimTopics[address(_trustedIssuer)] = _claimTopics;
        for (uint256 i = 0; i < _claimTopics.length; i++) {
            s.claimTopicsToTrustedIssuers[_claimTopics[i]].push(_trustedIssuer);
        }
        emit ERC3643EventsLib.ClaimTopicsUpdated(_trustedIssuer, _claimTopics);
    }

    /**
     *  @dev See {ITrustedIssuersRegistry-getTrustedIssuers}.
     */
    function getTrustedIssuers() external view override returns (IClaimIssuer[] memory) {
        Storage storage s = _getStorage();
        uint256 length = s.trustedIssuers.length();
        IClaimIssuer[] memory result = new IClaimIssuer[](length);
        for (uint256 i = 0; i < length; i++) {
            result[i] = IClaimIssuer(s.trustedIssuers.at(i));
        }
        return result;
    }

    /**
     *  @dev See {ITrustedIssuersRegistry-getTrustedIssuersForClaimTopic}.
     */
    function getTrustedIssuersForClaimTopic(uint256 claimTopic) external view override returns (IClaimIssuer[] memory) {
        return _getStorage().claimTopicsToTrustedIssuers[claimTopic];
    }

    /**
     *  @dev See {ITrustedIssuersRegistry-isTrustedIssuer}.
     */
    function isTrustedIssuer(address _issuer) external view override returns (bool) {
        return _getStorage().trustedIssuers.contains(_issuer);
    }

    /**
     *  @dev See {ITrustedIssuersRegistry-getTrustedIssuerClaimTopics}.
     */
    function getTrustedIssuerClaimTopics(IClaimIssuer _trustedIssuer)
        external
        view
        override
        returns (uint256[] memory)
    {
        Storage storage s = _getStorage();
        require(s.trustedIssuers.contains(address(_trustedIssuer)), ErrorsLib.TrustedIssuerDoesNotExist());
        return s.trustedIssuerClaimTopics[address(_trustedIssuer)];
    }

    /**
     *  @dev See {ITrustedIssuersRegistry-hasClaimTopic}.
     */
    function hasClaimTopic(address _issuer, uint256 _claimTopic) external view override returns (bool) {
        Storage storage s = _getStorage();
        uint256 length = s.trustedIssuerClaimTopics[_issuer].length;
        uint256[] memory claimTopics = s.trustedIssuerClaimTopics[_issuer];
        for (uint256 i = 0; i < length; i++) {
            if (claimTopics[i] == _claimTopic) {
                return true;
            }
        }
        return false;
    }

    /**
     *  @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IERC3643TrustedIssuersRegistry).interfaceId
            || interfaceId == type(IERC173).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function _addTrustedIssuer(IClaimIssuer _trustedIssuer, uint256[] memory _claimTopics) internal {
        require(address(_trustedIssuer) != address(0), ErrorsLib.ZeroAddress());

        Storage storage s = _getStorage();
        require(!s.trustedIssuers.contains(address(_trustedIssuer)), ErrorsLib.TrustedIssuerAlreadyExists());
        require(_claimTopics.length > 0, ErrorsLib.TrustedClaimTopicsCannotBeEmpty());
        require(_claimTopics.length <= 15, ErrorsLib.MaxClaimTopcisReached(15));
        require(s.trustedIssuers.length() < 50, ErrorsLib.MaxTrustedIssuersReached(50));
        s.trustedIssuers.add(address(_trustedIssuer));
        s.trustedIssuerClaimTopics[address(_trustedIssuer)] = _claimTopics;
        for (uint256 i = 0; i < _claimTopics.length; i++) {
            s.claimTopicsToTrustedIssuers[_claimTopics[i]].push(_trustedIssuer);
        }
        emit ERC3643EventsLib.TrustedIssuerAdded(_trustedIssuer, _claimTopics);
    }

    function _getStorage() internal pure returns (Storage storage s) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            s.slot := STORAGE_LOCATION
        }
    }

}
