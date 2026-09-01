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

import { ErrorsLib } from "../../../libraries/ErrorsLib.sol";
import { ModuleCapabilitiesLib } from "../../../libraries/ModuleCapabilitiesLib.sol";
import {
    AccessManagedOwnableBase,
    AccessManagedOwnableUpgradeable
} from "../../../utils/AccessManagedOwnableUpgradeable.sol";
import { AbstractModuleUpgradeable } from "./AbstractModuleUpgradeable.sol";
import { IModule } from "./IModule.sol";

/// @title SpenderWhitelistModule
/// @dev Restricts `transferFrom` to an allowlist of operators the issuer named, per compliance.
/// Default closed: a freshly bound module blocks every `transferFrom` until someone is listed, so
/// bind it with `addAndSetModule` to list in the same transaction.
/// Entries are keyed by the bind nonce, so an unbind discards the list.
contract SpenderWhitelistModule is AbstractModuleUpgradeable, AccessManagedOwnableUpgradeable {

    /// @dev Emitted when a spender is allowed to move tokens on behalf of holders.
    /// @param _compliance compliance contract the allowlist belongs to
    /// @param _spender address allowed to call `transferFrom`
    event SpenderAllowed(address indexed _compliance, address indexed _spender);

    /// @dev Emitted when a spender loses that authorization.
    /// @param _compliance compliance contract the allowlist belongs to
    /// @param _spender address no longer allowed to call `transferFrom`
    event SpenderDisallowed(address indexed _compliance, address indexed _spender);

    /// @custom:storage-location erc7201:ERC3643.storage.SpenderWhitelist
    struct SpenderWhitelistStorage {
        /// allowlist per compliance, scoped by the bind nonce so an unbind invalidates every entry at
        /// once, without iterating storage.
        /// Example: compliance C binds, its nonce is 0, and `allowSpender(alice)` writes
        /// `allowedSpenders[C][0][alice] = true`. C unbinds and the nonce becomes 1. On re-bind, reads
        /// use nonce 1, so alice is not allowed anymore; listing her again writes
        /// `allowedSpenders[C][1][alice]` and the nonce-0 entries stay behind as harmless orphans.
        mapping(address compliance => mapping(uint256 nonce => mapping(address spender => bool))) allowedSpenders;
    }

    // keccak256(abi.encode(uint256(keccak256("ERC3643.storage.SpenderWhitelist")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _SPENDER_WHITELIST_STORAGE_LOCATION =
        0x5812fc22578328f47b9e6cc9cd4b23cdee5afcb5c752c16bb48975c028b9ff00;

    constructor() {
        _disableInitializers();
    }

    /// @dev Initializes the module behind its proxy, with an empty allowlist.
    /// @param accessManagerAddress authority gating the implementation upgrade
    function initialize(address accessManagerAddress) external initializer {
        require(accessManagerAddress != address(0), ErrorsLib.ZeroAddress());

        __AbstractModule_init();
        __AccessManaged_init(accessManagerAddress);
    }

    /// @dev Lists a spender for the calling compliance. Driven by the compliance owner through
    /// `callModuleFunction`. Emits `SpenderAllowed`.
    /// @param _spender address allowed to move tokens on behalf of holders
    function allowSpender(address _spender) external onlyComplianceCall {
        require(_spender != address(0), ErrorsLib.ZeroAddress());

        SpenderWhitelistStorage storage s = _getSpenderWhitelistStorage();
        uint256 nonce = getNonce(msg.sender);
        require(!s.allowedSpenders[msg.sender][nonce][_spender], ErrorsLib.SpenderAlreadyAllowed(_spender));

        s.allowedSpenders[msg.sender][nonce][_spender] = true;
        emit SpenderAllowed(msg.sender, _spender);
    }

    /// @dev Delists a spender for the calling compliance. Emits `SpenderDisallowed`.
    /// @param _spender address to delist
    function disallowSpender(address _spender) external onlyComplianceCall {
        SpenderWhitelistStorage storage s = _getSpenderWhitelistStorage();
        uint256 nonce = getNonce(msg.sender);
        require(s.allowedSpenders[msg.sender][nonce][_spender], ErrorsLib.SpenderNotListed(_spender));

        s.allowedSpenders[msg.sender][nonce][_spender] = false;
        emit SpenderDisallowed(msg.sender, _spender);
    }

    /// @inheritdoc IModule
    /// @return true if the spender is on the allowlist of the compliance
    function moduleCheckSpender(address _spender, address, address, uint256, address _compliance)
        external
        view
        override
        returns (bool)
    {
        return isSpenderAllowed(_compliance, _spender);
    }

    /// @inheritdoc IModule
    /// @return the bitmask of the dispatch points this module implements
    function moduleCapabilities() external pure returns (uint256) {
        return ModuleCapabilitiesLib.CHECK_SPENDER;
    }

    /// @inheritdoc IModule
    /// @dev Nothing to verify: the allowlist starts empty whatever the compliance looks like.
    /// @return always true
    function canComplianceBind(address) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IModule
    /// @dev Binds anywhere, but blocks every `transferFrom` until an operator is listed.
    /// @return always true
    function isPlugAndPlay() external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IModule
    /// @return _name the name of the module
    function name() external pure returns (string memory _name) {
        return "SpenderWhitelistModule";
    }

    /// @dev Allowlist status of a spender, resolved at the compliance's current bind nonce.
    /// @param _compliance compliance contract the allowlist belongs to
    /// @param _spender address to look up
    /// @return true if the spender may call `transferFrom` under `_compliance`
    function isSpenderAllowed(address _compliance, address _spender) public view returns (bool) {
        return _getSpenderWhitelistStorage().allowedSpenders[_compliance][getNonce(_compliance)][_spender];
    }

    /// @inheritdoc AccessManagedOwnableBase
    /// @param interfaceId the interface identifier, as specified in ERC-165
    /// @return true if the contract implements `interfaceId`
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AbstractModuleUpgradeable, AccessManagedOwnableBase)
        returns (bool)
    {
        return AbstractModuleUpgradeable.supportsInterface(interfaceId)
            || AccessManagedOwnableBase.supportsInterface(interfaceId);
    }

    /// @dev Gated through the shared authority.
    function _authorizeUpgrade(address) internal override restricted { }

    /// @dev Resolves the ERC-7201 namespaced storage of this module.
    /// @return s the module storage struct
    function _getSpenderWhitelistStorage() private pure returns (SpenderWhitelistStorage storage s) {
        assembly ("memory-safe") {
            s.slot := _SPENDER_WHITELIST_STORAGE_LOCATION
        }
    }

}
