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

import { AuthorityUtils } from "@openzeppelin/contracts/access/manager/AuthorityUtils.sol";
import { LowLevelCall } from "@openzeppelin/contracts/utils/LowLevelCall.sol";
import { EnumerableMap } from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import { IERC3643Compliance } from "../../ERC-3643/IERC3643Compliance.sol";
import { ERC3643Compliance } from "../../ERC-3643/base/ERC3643Compliance.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { ModuleCapabilitiesLib } from "../../libraries/ModuleCapabilitiesLib.sol";
import { RolesLib } from "../../libraries/RolesLib.sol";
import { AccessManagedOwnableUpgradeable } from "../../utils/AccessManagedOwnableUpgradeable.sol";
import { IModularCompliance } from "./IModularCompliance.sol";
import { IModule } from "./modules/IModule.sol";

/// @title ModularCompliance
/// @notice T-REX compliance: the standard ERC-3643 compliance surface plus the module system that
///  supplies the actual rules.
/// @dev Layer 3 of the ERC-3643 / T-REX split (see issue #65). The standard surface -- token binding,
///  `canTransfer` and the three notification hooks -- and the bound-token state live in
///  {ERC3643Compliance}. This contract adds everything T-REX-specific, in its own ERC-7201 namespace:
///
///  - the bound module set with the dispatch points each module declares (#23);
///  - rule evaluation, by implementing the base's `_canTransfer`, `_transferred`, `_created` and
///    `_destroyed` hooks as capability-filtered dispatch over that set;
///  - the spender check `canSpenderCall` (#4), a T-REX-only external function;
///  - AccessManager-based authorization, including the "the token may bind itself once, the owner may
///    always bind" policy expressed in `_authorizeTokenBinding`.
///
///  Nothing here writes the base namespace directly; the binding goes through the base's internal
///  functions.
contract ModularCompliance is IModularCompliance, ERC3643Compliance, AccessManagedOwnableUpgradeable {

    using EnumerableMap for EnumerableMap.AddressToUintMap;

    /// @custom:storage-location erc7201:ERC3643.storage.ModularCompliance
    struct Storage {
        /// Bound modules, each mapped to the dispatch points it declares.
        EnumerableMap.AddressToUintMap modules;
    }

    // keccak256(abi.encode(uint256(keccak256("ERC3643.storage.ModularCompliance")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant STORAGE_LOCATION = 0x44b49c37d3109105ef492022bec834e94dca859d191a0d5323d3afbc4aa69400;

    constructor() {
        _disableInitializers();
    }

    function init(
        address tokenAddress,
        address accessManagerAddress,
        address[] calldata modules,
        bytes[] calldata moduleSettings
    ) external initializer {
        require(tokenAddress != address(0) && accessManagerAddress != address(0), ErrorsLib.ZeroAddress());
        require(modules.length >= moduleSettings.length, ErrorsLib.InvalidCompliancePattern());

        __AccessManaged_init(accessManagerAddress);

        _bindToken(tokenAddress);

        for (uint256 i = 0; i < modules.length; i++) {
            _addModule(modules[i]);
            if (i < moduleSettings.length) {
                _callModuleFunction(moduleSettings[i], modules[i]);
            }
        }
    }

    /**
     *  @dev See {IModularCompliance-removeModule}.
     */
    function removeModule(address _module) external restricted {
        require(_module != address(0), ErrorsLib.ZeroAddress());

        require(_getStorage().modules.remove(_module), ErrorsLib.ModuleNotBound());
        IModule(_module).unbindCompliance(address(this));
        emit EventsLib.ModuleRemoved(_module);
    }

    /**
     *  @dev See {IModularCompliance-refreshModuleCapabilities}.
     */
    function refreshModuleCapabilities(address _module) external restricted {
        Storage storage s = _getStorage();
        require(s.modules.contains(_module), ErrorsLib.ModuleNotBound());

        uint256 capabilities = _readCapabilities(_module);
        s.modules.set(_module, capabilities);

        emit EventsLib.ModuleCapabilitiesRecorded(_module, capabilities);
    }

    /**
     *  @dev See {IModularCompliance-addAndSetModule}.
     */
    function addAndSetModule(address _module, bytes[] calldata _interactions) external restricted {
        require(_interactions.length <= 5, ErrorsLib.ArraySizeLimited(5));
        _addModule(_module);
        for (uint256 i = 0; i < _interactions.length; i++) {
            _callModuleFunction(_interactions[i], _module);
        }
    }

    /**
     *  @dev See {IModularCompliance-isModuleBound}.
     */
    function isModuleBound(address _module) external view returns (bool) {
        return _getStorage().modules.contains(_module);
    }

    /**
     *  @dev See {IModularCompliance-getModules}.
     */
    function getModules() external view returns (address[] memory) {
        return _getStorage().modules.keys();
    }

    /**
     *  @dev See {IModularCompliance-getModuleCapabilities}.
     */
    function getModuleCapabilities(address _module) external view returns (uint256) {
        Storage storage s = _getStorage();
        require(s.modules.contains(_module), ErrorsLib.ModuleNotBound());
        return s.modules.get(_module);
    }

    /**
     *  @dev See {IModularCompliance-getModulesByCapability}.
     */
    function getModulesByCapability(uint256 _capability) external view returns (address[] memory) {
        Storage storage s = _getStorage();
        uint256 length = s.modules.length();
        address[] memory matched = new address[](length);
        uint256 count;
        for (uint256 i = 0; i < length; i++) {
            (address module, uint256 capabilities) = s.modules.pos(i);
            if (capabilities & _capability != 0) {
                matched[count++] = module;
            }
        }
        assembly ("memory-safe") {
            mstore(matched, count)
        }
        return matched;
    }

    /**
     *  @dev See {IModularCompliance-canSpenderCall}.
     */
    function canSpenderCall(address _spender, address _from, address _to, uint256 _value) external view returns (bool) {
        Storage storage s = _getStorage();
        uint256 length = s.modules.length();
        for (uint256 i = 0; i < length; i++) {
            (address module, uint256 capabilities) = s.modules.pos(i);
            if (
                capabilities & ModuleCapabilitiesLib.CHECK_SPENDER != 0
                    && !IModule(module).moduleCheckSpender(_spender, _from, _to, _value, address(this))
            ) {
                return false;
            }
        }

        return true;
    }

    /**
     *  @dev See {IModularCompliance-addModule}.
     */
    function addModule(address _module) public restricted {
        _addModule(_module);
    }

    /**
     *  @dev see {IModularCompliance-callModuleFunction}.
     */
    function callModuleFunction(bytes calldata callData, address _module) public restricted {
        _callModuleFunction(callData, _module);
    }

    /**
     *  @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IModularCompliance).interfaceId
            || interfaceId == type(IERC3643Compliance).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @dev Binding policy: an unbound compliance accepts a bind from the token itself (so a Token can
    ///  claim a fresh compliance during setup), and the owner may always bind or unbind.
    function _authorizeTokenBinding(address token) internal view override {
        require(
            (_getTokenBound() == address(0) && msg.sender == token) || _isOwner(msg.sender),
            ErrorsLib.OnlyOwnerOrTokenCanCall()
        );
    }

    /// @dev Unbinding does not allow the "first bind" path: only the token itself or the owner.
    function _authorizeTokenUnbinding(address token) internal view override {
        require(msg.sender == token || _isOwner(msg.sender), ErrorsLib.OnlyOwnerOrTokenCanCall());
    }

    /// @dev Rule evaluation: every module declaring `CHECK_TRANSFER` must accept the transfer.
    function _canTransfer(address from, address to, uint256 value) internal view override returns (bool) {
        Storage storage s = _getStorage();
        uint256 length = s.modules.length();
        for (uint256 i = 0; i < length; i++) {
            (address module, uint256 capabilities) = s.modules.pos(i);
            if (
                capabilities & ModuleCapabilitiesLib.CHECK_TRANSFER != 0
                    && !IModule(module).moduleCheck(from, to, value, address(this))
            ) {
                return false;
            }
        }

        return true;
    }

    /// @dev Notifies every module declaring `HOOK_TRANSFER`.
    function _transferred(address from, address to, uint256 value) internal override {
        Storage storage s = _getStorage();
        uint256 length = s.modules.length();
        for (uint256 i = 0; i < length; i++) {
            (address module, uint256 capabilities) = s.modules.pos(i);
            if (capabilities & ModuleCapabilitiesLib.HOOK_TRANSFER != 0) {
                IModule(module).moduleTransferAction(from, to, value);
            }
        }
    }

    /// @dev Notifies every module declaring `HOOK_MINT`.
    function _created(address to, uint256 value) internal override {
        Storage storage s = _getStorage();
        uint256 length = s.modules.length();
        for (uint256 i = 0; i < length; i++) {
            (address module, uint256 capabilities) = s.modules.pos(i);
            if (capabilities & ModuleCapabilitiesLib.HOOK_MINT != 0) {
                IModule(module).moduleMintAction(to, value);
            }
        }
    }

    /// @dev Notifies every module declaring `HOOK_BURN`.
    function _destroyed(address from, uint256 value) internal override {
        Storage storage s = _getStorage();
        uint256 length = s.modules.length();
        for (uint256 i = 0; i < length; i++) {
            (address module, uint256 capabilities) = s.modules.pos(i);
            if (capabilities & ModuleCapabilitiesLib.HOOK_BURN != 0) {
                IModule(module).moduleBurnAction(from, value);
            }
        }
    }

    /// @dev Binds a module with the existing validation rules (zero check, duplicate check, cap of 25,
    ///  plug-and-play / canComplianceBind requirement) and records the dispatch points it declares.
    ///  No caller check — wrappers enforce it. Everything is validated before any state is written,
    ///  so `canComplianceBind` sees the module as not yet bound.
    function _addModule(address _module) internal {
        require(_module != address(0), ErrorsLib.ZeroAddress());
        Storage storage s = _getStorage();
        require(s.modules.length() < 25, ErrorsLib.MaxModulesReached(25));
        require(!s.modules.contains(_module), ErrorsLib.ModuleAlreadyBound());
        IModule module = IModule(_module);
        require(
            module.isPlugAndPlay() || module.canComplianceBind(address(this)),
            ErrorsLib.ComplianceNotSuitableForBindingToModule(_module)
        );

        uint256 capabilities = _readCapabilities(_module);
        s.modules.set(_module, capabilities);

        module.bindCompliance(address(this));

        emit EventsLib.ModuleAdded(_module);
        emit EventsLib.ModuleCapabilitiesRecorded(_module, capabilities);
    }

    /// @dev Reads a module's declaration and rejects anything the compliance cannot route.
    function _readCapabilities(address _module) internal pure returns (uint256 capabilities) {
        capabilities = IModule(_module).moduleCapabilities();
        require(capabilities != 0, ErrorsLib.ModuleHasNoCapabilities());
        require(capabilities & ~ModuleCapabilitiesLib.ALL == 0, ErrorsLib.InvalidModuleCapabilities(capabilities));
    }

    /// @dev Forwards `callData` to a bound `_module` via low-level call and emits the interaction event.
    ///  Reverts when `_module` is not bound or when the underlying call fails. No caller check — wrappers enforce it.
    function _callModuleFunction(bytes calldata callData, address _module) internal {
        require(_getStorage().modules.contains(_module), ErrorsLib.ModuleNotBound());

        if (!LowLevelCall.callNoReturn(_module, callData)) {
            LowLevelCall.bubbleRevert();
        }

        emit EventsLib.ModuleInteraction(_module, callData);
    }

    function _isOwner(address caller) internal view returns (bool) {
        (bool isOwner,) =
            AuthorityUtils.canCallWithDelay(authority(), caller, address(this), RolesLib.BIND_UNBIND_TOKEN);
        return isOwner;
    }

    function _getStorage() internal pure returns (Storage storage s) {
        assembly ("memory-safe") {
            s.slot := STORAGE_LOCATION
        }
    }

}
