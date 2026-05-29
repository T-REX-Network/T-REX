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

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { ERC3643EventsLib } from "../../ERC-3643/ERC3643EventsLib.sol";
import { IERC3643Compliance } from "../../ERC-3643/IERC3643Compliance.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { RolesLib } from "../../libraries/RolesLib.sol";
import { IERC173 } from "../../roles/IERC173.sol";
import { IModularCompliance } from "./IModularCompliance.sol";
import { IModule } from "./modules/IModule.sol";

contract ModularCompliance is IModularCompliance, OwnableUpgradeable, AccessManagedUpgradeable, IERC165 {

    using EnumerableSet for EnumerableSet.AddressSet;

    /// @custom:storage-location erc7201:ERC3643.storage.ModularCompliance
    struct Storage {
        /// token linked to the compliance contract
        address tokenBound;
        /// Set of modules bound to the compliance
        EnumerableSet.AddressSet modules;
    }

    // keccak256(abi.encode(uint256(keccak256("ERC3643.storage.ModularCompliance")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant STORAGE_LOCATION = 0x44b49c37d3109105ef492022bec834e94dca859d191a0d5323d3afbc4aa69400;

    /// modifiers
    /**
     * @dev Throws if called by any address that is not a token bound to the compliance.
     */
    modifier onlyBoundedToken() {
        _checkOnlyBoundedToken();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /**
     *  @dev Initializes the modular compliance with the access manager, the bound token, the initial set of
     *       modules and matching module settings.
     *  @param accessManagerAddress address of the access manager
     *  @param _token address of the token bound to this compliance — pre-computed via CREATE3 by the factory so
     *         the compliance never needs the deprecated `Token-self-bind` indirection
     *  @param _modules initial set of modules to bind (capped at 25 — matches the existing post-init cap)
     *  @param _moduleSettings optional per-module settings forwarded via `_callModuleFunction` after each module is
     *         bound. `_moduleSettings.length` must be `<= _modules.length`; settings beyond `_modules.length` are
     *         not accepted
     *  emits a `TokenBound` event
     *  emits a `ModuleAdded` event for each module
     *  emits a `ModuleInteraction` event for each `_moduleSettings[i]` applied
     */
    function init(
        address accessManagerAddress,
        address _token,
        address[] calldata _modules,
        bytes[] calldata _moduleSettings
    ) external initializer {
        require(_token != address(0), ErrorsLib.ZeroAddress());
        require(_modules.length >= _moduleSettings.length, ErrorsLib.InvalidCompliancePattern());
        require(_modules.length <= 25, ErrorsLib.MaxModulesReached(25));

        __AccessManaged_init(accessManagerAddress);
        __Ownable_init(accessManagerAddress);
        _bindToken(_token);

        for (uint256 i = 0; i < _modules.length; i++) {
            if (!_getStorage().modules.contains(_modules[i])) {
                _addModule(_modules[i]);
            }
            if (i < _moduleSettings.length) {
                _callModuleFunction(_moduleSettings[i], _modules[i]);
            }
        }
    }

    /**
     *  @dev See {IERC3643Compliance-bindToken}.
     */
    function bindToken(address _token) external override {
        Storage storage s = _getStorage();
        require(
            _isOwner(msg.sender) || (s.tokenBound == address(0) && msg.sender == _token),
            ErrorsLib.OnlyOwnerOrTokenCanCall()
        );
        _bindToken(_token);
    }

    /**
     *  @dev See {IERC3643Compliance-unbindToken}.
     */
    function unbindToken(address _token) external override {
        require(_isOwner(msg.sender) || msg.sender == _token, ErrorsLib.OnlyOwnerOrTokenCanCall());

        Storage storage s = _getStorage();
        require(_token == s.tokenBound, ErrorsLib.TokenNotBound());
        require(_token != address(0), ErrorsLib.ZeroAddress());
        delete s.tokenBound;
        emit ERC3643EventsLib.TokenUnbound(_token);
    }

    /**
     *  @dev See {IModularCompliance-removeModule}.
     */
    function removeModule(address _module) external override restricted {
        require(_module != address(0), ErrorsLib.ZeroAddress());

        Storage storage s = _getStorage();
        require(s.modules.contains(_module), ErrorsLib.ModuleNotBound());
        IModule(_module).unbindCompliance(address(this));
        s.modules.remove(_module);
        emit EventsLib.ModuleRemoved(_module);
    }

    /**
     *  @dev See {IERC3643Compliance-transferred}.
     */
    function transferred(address _from, address _to, uint256 _value) external override onlyBoundedToken {
        require(_from != address(0) && _to != address(0), ErrorsLib.ZeroAddress());
        require(_value > 0, ErrorsLib.ZeroValue());
        Storage storage s = _getStorage();
        uint256 length = s.modules.length();
        for (uint256 i = 0; i < length; i++) {
            IModule(s.modules.at(i)).moduleTransferAction(_from, _to, _value);
        }
    }

    /**
     *  @dev See {IERC3643Compliance-created}.
     */
    function created(address _to, uint256 _value) external override onlyBoundedToken {
        require(_to != address(0), ErrorsLib.ZeroAddress());
        require(_value > 0, ErrorsLib.ZeroValue());
        Storage storage s = _getStorage();
        uint256 length = s.modules.length();
        for (uint256 i = 0; i < length; i++) {
            IModule(s.modules.at(i)).moduleMintAction(_to, _value);
        }
    }

    /**
     *  @dev See {IERC3643Compliance-destroyed}.
     */
    function destroyed(address _from, uint256 _value) external override onlyBoundedToken {
        require(_from != address(0), ErrorsLib.ZeroAddress());
        require(_value > 0, ErrorsLib.ZeroValue());
        Storage storage s = _getStorage();
        uint256 length = s.modules.length();
        for (uint256 i = 0; i < length; i++) {
            IModule(s.modules.at(i)).moduleBurnAction(_from, _value);
        }
    }

    /**
     *  @dev See {IModularCompliance-addAndSetModule}.
     */
    function addAndSetModule(address _module, bytes[] calldata _interactions) external override restricted {
        require(_interactions.length <= 5, ErrorsLib.ArraySizeLimited(5));
        _addModule(_module);
        for (uint256 i = 0; i < _interactions.length; i++) {
            _callModuleFunction(_interactions[i], _module);
        }
    }

    /**
     *  @dev See {IModularCompliance-isModuleBound}.
     */
    function isModuleBound(address _module) external view override returns (bool) {
        return _getStorage().modules.contains(_module);
    }

    /**
     *  @dev See {IModularCompliance-getModules}.
     */
    function getModules() external view override returns (address[] memory) {
        return _getStorage().modules.values();
    }

    /**
     *  @dev See {IERC3643Compliance-getTokenBound}.
     */
    function getTokenBound() external view override returns (address) {
        return _getStorage().tokenBound;
    }

    /**
     *  @dev See {IERC3643Compliance-getTokenBound}.
     */
    function isTokenBound(address _token) external view override returns (bool) {
        return _token == _getStorage().tokenBound;
    }

    /**
     *  @dev See {IERC3643Compliance-canTransfer}.
     */
    function canTransfer(address _from, address _to, uint256 _value) external view override returns (bool) {
        Storage storage s = _getStorage();
        uint256 length = s.modules.length();
        for (uint256 i = 0; i < length; i++) {
            if (!IModule(s.modules.at(i)).moduleCheck(_from, _to, _value, address(this))) {
                return false;
            }
        }

        return true;
    }

    /**
     *  @dev See {IModularCompliance-addModule}.
     */
    function addModule(address _module) public override restricted {
        _addModule(_module);
    }

    /**
     *  @dev see {IModularCompliance-callModuleFunction}.
     */
    function callModuleFunction(bytes calldata callData, address _module) public override restricted {
        _callModuleFunction(callData, _module);
    }

    /**
     *  @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IModularCompliance).interfaceId
            || interfaceId == type(IERC3643Compliance).interfaceId || interfaceId == type(IERC173).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    /// @dev Sets the bound token on the compliance storage and emits the corresponding event.
    ///      No caller check — the public `bindToken` wrapper enforces the owner/Token-self-bind policy.
    function _bindToken(address _token) internal {
        require(_token != address(0), ErrorsLib.ZeroAddress());
        _getStorage().tokenBound = _token;
        emit ERC3643EventsLib.TokenBound(_token);
    }

    /// @dev Binds a module to the compliance with the existing validation rules (zero check, duplicate check,
    ///      cap of 25, plug-and-play / canComplianceBind requirement). No caller check — wrappers enforce it.
    function _addModule(address _module) internal {
        require(_module != address(0), ErrorsLib.ZeroAddress());
        Storage storage s = _getStorage();
        require(!s.modules.contains(_module), ErrorsLib.ModuleAlreadyBound());
        require(s.modules.length() < 25, ErrorsLib.MaxModulesReached(25));
        IModule module = IModule(_module);
        require(
            module.isPlugAndPlay() || module.canComplianceBind(address(this)),
            ErrorsLib.ComplianceNotSuitableForBindingToModule(_module)
        );

        module.bindCompliance(address(this));
        s.modules.add(_module);
        emit EventsLib.ModuleAdded(_module);
    }

    /// @dev Forwards `callData` to a bound `_module` via low-level call and emits the interaction event.
    ///      Reverts when `_module` is not bound or when the underlying call fails. No caller check —
    ///      wrappers enforce it.
    function _callModuleFunction(bytes calldata callData, address _module) internal {
        require(_getStorage().modules.contains(_module), ErrorsLib.ModuleNotBound());
        // NOTE: Use assembly to call the interaction instead of a low level
        // call for two reasons:
        // - We don't want to copy the return data, since we discard it for
        // interactions.
        // - Solidity will under certain conditions generate code to copy input
        // calldata twice to memory (the second being a "memcopy loop").
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let freeMemoryPointer := mload(0x40) // Load the free memory pointer from memory location 0x40

            // Copy callData from calldata to the free memory location
            calldatacopy(freeMemoryPointer, callData.offset, callData.length)

            if iszero( // Check if the call returns zero (indicating failure)
                call( // Perform the external call
                    gas(), // Provide all available gas
                    _module, // Address of the target module
                    0, // No ether is sent with the call
                    freeMemoryPointer, // Input data starts at the free memory pointer
                    callData.length, // Input data length
                    0, // Output data location (not used)
                    0 // Output data size (not used)
                )
            ) {
                returndatacopy(0, 0, returndatasize()) // Copy return data to memory starting at position 0
                revert(0, returndatasize()) // Revert the transaction with the return data
            }
        }

        emit EventsLib.ModuleInteraction(_module, _selector(callData));
    }

    /// @dev Extracts the Solidity ABI selector for the specified interaction.
    /// @param callData Interaction data.
    /// @return result The 4 byte function selector of the call encoded in this interaction.
    function _selector(bytes calldata callData) internal pure returns (bytes4 result) {
        if (callData.length >= 4) {
            // NOTE: Read the first word of the interaction's calldata. The
            // value does not need to be shifted since `bytesN` values are left
            // aligned, and the value does not need to be masked since masking
            // occurs when the value is accessed and not stored:
            // <https://docs.soliditylang.org/en/v0.7.6/abi-spec.html#encoding-of-indexed-event-parameters>
            // <https://docs.soliditylang.org/en/v0.7.6/assembly.html#access-to-external-variables-functions-and-libraries>
            assembly {
                result := calldataload(callData.offset)
            }
        }
    }

    function _isOwner(address sender) internal view returns (bool) {
        (bool isOwner,) = IAccessManager(authority()).hasRole(RolesLib.OWNER, sender);
        return isOwner;
    }

    function _getStorage() internal pure returns (Storage storage s) {
        assembly {
            s.slot := STORAGE_LOCATION
        }
    }

    function _checkOnlyBoundedToken() private view {
        require(msg.sender == _getStorage().tokenBound, ErrorsLib.AddressNotATokenBoundToComplianceContract());
    }

}
