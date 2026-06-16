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

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    AccessManagedUpgradeable,
    IAccessManager
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { LowLevelCall } from "@openzeppelin/contracts/utils/LowLevelCall.sol";
import { ERC165Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { ERC3643EventsLib } from "../../ERC-3643/ERC3643EventsLib.sol";
import { IERC3643Compliance } from "../../ERC-3643/IERC3643Compliance.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { RolesLib } from "../../libraries/RolesLib.sol";
import { IERC173 } from "../../vendor/IERC173.sol";
import { IModularCompliance } from "./IModularCompliance.sol";
import { IModule } from "./modules/IModule.sol";

contract ModularCompliance is IModularCompliance, OwnableUpgradeable, AccessManagedUpgradeable, ERC165Upgradeable {

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
        require(msg.sender == _getStorage().tokenBound, ErrorsLib.AddressNotATokenBoundToComplianceContract());
        _;
    }

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

        __Ownable_init(accessManagerAddress);
        __AccessManaged_init(accessManagerAddress);
        __ERC165_init();

        _bindToken(tokenAddress);

        for (uint256 i = 0; i < modules.length; i++) {
            _addModule(modules[i]);
            if (i < moduleSettings.length) {
                _callModuleFunction(moduleSettings[i], modules[i]);
            }
        }
    }

    /**
     *  @dev See {IERC3643Compliance-bindToken}.
     */
    function bindToken(address _token) external {
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
    function unbindToken(address _token) external {
        require(_isOwner(msg.sender) || msg.sender == _token, ErrorsLib.OnlyOwnerOrTokenCanCall());

        Storage storage s = _getStorage();
        require(_token != address(0), ErrorsLib.ZeroAddress());
        require(_token == s.tokenBound, ErrorsLib.TokenNotBound());
        delete s.tokenBound;
        emit ERC3643EventsLib.TokenUnbound(_token);
    }

    /**
     *  @dev See {IModularCompliance-removeModule}.
     */
    function removeModule(address _module) external restricted {
        require(_module != address(0), ErrorsLib.ZeroAddress());

        Storage storage s = _getStorage();
        require(s.modules.remove(_module), ErrorsLib.ModuleNotBound());
        IModule(_module).unbindCompliance(address(this));
        emit EventsLib.ModuleRemoved(_module);
    }

    /**
     *  @dev See {IERC3643Compliance-transferred}.
     */
    function transferred(address _from, address _to, uint256 _value) external onlyBoundedToken {
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
    function created(address _to, uint256 _value) external onlyBoundedToken {
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
    function destroyed(address _from, uint256 _value) external onlyBoundedToken {
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
        return _getStorage().modules.values();
    }

    /**
     *  @dev See {IERC3643Compliance-getTokenBound}.
     */
    function getTokenBound() external view returns (address) {
        return _getStorage().tokenBound;
    }

    /**
     *  @dev See {IERC3643Compliance-getTokenBound}.
     */
    function isTokenBound(address _token) external view returns (bool) {
        return _token == _getStorage().tokenBound;
    }

    /**
     *  @dev See {IERC3643Compliance-canTransfer}.
     */
    function canTransfer(address _from, address _to, uint256 _value) external view returns (bool) {
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
            || interfaceId == type(IERC3643Compliance).interfaceId || interfaceId == type(IERC173).interfaceId
            || super.supportsInterface(interfaceId);
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
        require(s.modules.length() < 25, ErrorsLib.MaxModulesReached(25));
        require(s.modules.add(_module), ErrorsLib.ModuleAlreadyBound());
        IModule module = IModule(_module);
        require(
            module.isPlugAndPlay() || module.canComplianceBind(address(this)),
            ErrorsLib.ComplianceNotSuitableForBindingToModule(_module)
        );

        module.bindCompliance(address(this));

        emit EventsLib.ModuleAdded(_module);
    }

    /// @dev Forwards `callData` to a bound `_module` via low-level call and emits the interaction event.
    ///      Reverts when `_module` is not bound or when the underlying call fails. No caller check — wrappers enforce it.
    function _callModuleFunction(bytes calldata callData, address _module) internal {
        require(_getStorage().modules.contains(_module), ErrorsLib.ModuleNotBound());

        if (!LowLevelCall.callNoReturn(_module, callData)) {
            LowLevelCall.bubbleRevert();
        }

        // For calldata shorter than 4 bytes the emitted "selector" is a zero-padded partial value rather than a real selector.
        // forge-lint: disable-next-line(unsafe-typecast)
        emit EventsLib.ModuleInteraction(_module, bytes4(callData));
    }

    function _isOwner(address sender) internal view returns (bool) {
        (bool isOwner,) = IAccessManager(authority()).hasRole(RolesLib.OWNER, sender);
        return isOwner;
    }

    function _getStorage() internal pure returns (Storage storage s) {
        assembly ("memory-safe") {
            s.slot := STORAGE_LOCATION
        }
    }

}

