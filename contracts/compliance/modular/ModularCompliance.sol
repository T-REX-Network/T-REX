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
import { ISettlementHandler } from "../../interop/ISettlementHandler.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { MessageTypesLib } from "../../libraries/MessageTypesLib.sol";
import { ModuleCapabilitiesLib } from "../../libraries/ModuleCapabilitiesLib.sol";
import { RolesLib } from "../../libraries/RolesLib.sol";
import { ITREXRegistry } from "../../registry/interface/ITREXRegistry.sol";
import { IToken } from "../../token/IToken.sol";
import { Token } from "../../token/Token.sol";
import { AccessManagedOwnableUpgradeable } from "../../utils/AccessManagedOwnableUpgradeable.sol";
import { IModularCompliance } from "./IModularCompliance.sol";
import { ITransferValidation } from "./ITransferValidation.sol";
import { TransferValidation } from "./TransferValidation.sol";
import { IModule } from "./modules/IModule.sol";

/// @title ModularCompliance
/// @dev {ERC3643Compliance} plus the module system that supplies the rules: the bound module set, the
/// capability-filtered dispatch implementing the base hooks, the `canSpenderCall` check, the
/// cross-chain validation lifecycle of {TransferValidation} and AccessManager authorization.
contract ModularCompliance is
    IModularCompliance,
    ISettlementHandler,
    ERC3643Compliance,
    TransferValidation,
    AccessManagedOwnableUpgradeable
{

    using EnumerableMap for EnumerableMap.AddressToUintMap;

    /// @custom:storage-location erc7201:erc3643.storage.TREXCompliance
    /// @dev A new namespace, not the old `ERC3643.storage.ModularCompliance`: `tokenBound` moved to the
    ///  standard base, so reusing the old one would shift `modules` up a slot. Migration in
    ///  docs/erc3643-oz-swap.md.
    struct Storage {
        /// Bound modules, each mapped to the dispatch points it declares.
        EnumerableMap.AddressToUintMap modules;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.TREXCompliance")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant STORAGE_LOCATION = 0xbd2da5c5fcdced9ef28c358fe4e316978613e6ee5dda1f35de5eca5813787500;

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
     *  Deletes the module from the routing set, then calls `unbindCompliance` on it directly so the module
     *  drops its own binding record. The call is not best effort on purpose: if the module reverts, or a
     *  caller supplies only enough gas for the outer call so the subcall runs out under the 63/64 rule, the
     *  whole removal reverts and the module stays bound on both sides. A module that reverts on
     *  `unbindCompliance` is removed with {forceRemoveModule}.
     *  Restricted to the configured AccessManager role (OWNER).
     *  Emits a ModuleRemoved event.
     *  @param _module address of the module to remove
     */
    function removeModule(address _module) external restricted {
        _removeModule(_module);
        IModule(_module).unbindCompliance(address(this));
        emit EventsLib.ModuleRemoved(_module);
    }

    /**
     *  @dev See {IModularCompliance-forceRemoveModule}.
     *  Deletes the module from the routing set without any call into it, so a module that reverts on
     *  `unbindCompliance` or everywhere cannot hold the token hostage. The module keeps its own binding
     *  record, so the same address cannot be added to this compliance again; a fresh deployment can.
     *  Restricted to the configured AccessManager role (OWNER).
     *  Emits a ModuleForceRemoved event and no ModuleRemoved, so indexers can tell a forced removal
     *  from a regular one.
     *  @param _module address of the module to remove
     */
    function forceRemoveModule(address _module) external restricted {
        _removeModule(_module);
        emit EventsLib.ModuleForceRemoved(_module);
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

    /// @inheritdoc ISettlementHandler
    function handleSettlement(bytes32 originChainKey, MessageTypesLib.SettlementNotification calldata notification)
        external
        onlyBoundToken
        returns (bool haltToken)
    {
        emit EventsLib.SettlementNotified(
            originChainKey, notification.validationId, notification.from, notification.to, notification.amount
        );
        return _handleSettlement(originChainKey, notification);
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

    /* ----- Validation settings ----- */

    /// @inheritdoc ITransferValidation
    function setDefaultValidityWindow(uint64 duration) external restricted {
        _setDefaultValidityWindow(duration);
    }

    /// @inheritdoc ITransferValidation
    function setReconciliationWindow(bytes32 chainKey, uint64 duration) external restricted {
        _setReconciliationWindow(chainKey, duration);
    }

    /// @inheritdoc ITransferValidation
    function setValidationClamp(uint256 maxAmount) external restricted {
        _setValidationClamp(maxAmount);
    }

    /// @inheritdoc ITransferValidation
    function pauseValidationIssuance(bytes32 chainKey) external restricted {
        _pauseIssuance(chainKey);
    }

    /// @inheritdoc ITransferValidation
    function unpauseValidationIssuance(bytes32 chainKey) external restricted {
        _unpauseIssuance(chainKey);
    }

    /// @inheritdoc ITransferValidation
    function discardExpiredValidations(uint256[] calldata validationIds) external restricted {
        _discardExpired(validationIds);
    }

    /**
     *  @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IModularCompliance).interfaceId
            || interfaceId == type(IERC3643Compliance).interfaceId
            || interfaceId == type(ISettlementHandler).interfaceId
            || interfaceId == type(ITransferValidation).interfaceId || super.supportsInterface(interfaceId);
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

    /* ----- What the validation layer needs ----- */

    /// @inheritdoc TransferValidation
    function _boundToken() internal view override returns (IToken) {
        return IToken(_getTokenBound());
    }

    /// @inheritdoc TransferValidation
    function _boundRegistry() internal view override returns (ITREXRegistry) {
        return ITREXRegistry(address(_boundToken().identityRegistry()));
    }

    /// @inheritdoc TransferValidation
    function _canCallSelector(address caller, bytes4 selector) internal view override returns (bool) {
        (bool immediate,) = AuthorityUtils.canCallWithDelay(authority(), caller, address(this), selector);
        return immediate;
    }

    /// @inheritdoc TransferValidation
    /// @dev Each module receives the range as the ones before it left it; its answer is intersected, never trusted.
    function _moduleBounds(
        bytes memory from,
        bytes memory to,
        bytes memory spender,
        uint256 currentMin,
        uint256 currentMax
    ) internal view override returns (uint256 min, uint256 max) {
        min = currentMin;
        max = currentMax;
        Storage storage s = _getStorage();
        uint256 length = s.modules.length();
        for (uint256 i = 0; i < length; i++) {
            (address module, uint256 capabilities) = s.modules.pos(i);
            if (capabilities & ModuleCapabilitiesLib.BOUNDS == 0) continue;
            (uint256 moduleMin, uint256 moduleMax) =
                IModule(module).validationBounds(from, to, spender, min, max, address(this));
            if (moduleMin > min) min = moduleMin;
            if (moduleMax < max) max = moduleMax;
        }
    }

    /// @inheritdoc TransferValidation
    function _reserveSlots(uint256 validationId, bytes memory from, bytes memory to, uint256 amountMax)
        internal
        override
    {
        Storage storage s = _getStorage();
        uint256 length = s.modules.length();
        for (uint256 i = 0; i < length; i++) {
            (address module, uint256 capabilities) = s.modules.pos(i);
            if (capabilities & ModuleCapabilitiesLib.SLOTS != 0) {
                IModule(module).reserveSlot(validationId, from, to, amountMax);
            }
        }
    }

    /// @inheritdoc TransferValidation
    function _commitSlots(uint256 validationId, uint256 executedAmount) internal override returns (bool breachesRule) {
        Storage storage s = _getStorage();
        uint256 length = s.modules.length();
        for (uint256 i = 0; i < length; i++) {
            (address module, uint256 capabilities) = s.modules.pos(i);
            if (capabilities & ModuleCapabilitiesLib.SLOTS != 0) {
                // Every declaring module is committed; one breach is enough, but none of them may be skipped.
                if (IModule(module).commitSlot(validationId, executedAmount)) breachesRule = true;
            }
        }
    }

    /// @inheritdoc TransferValidation
    function _releaseSlots(uint256 validationId) internal override {
        Storage storage s = _getStorage();
        uint256 length = s.modules.length();
        for (uint256 i = 0; i < length; i++) {
            (address module, uint256 capabilities) = s.modules.pos(i);
            if (capabilities & ModuleCapabilitiesLib.SLOTS != 0) {
                IModule(module).releaseSlot(validationId);
            }
        }
    }

    /// @inheritdoc TransferValidation
    /// @dev The token is the wire's only author: it pins the route per leg and refuses a closed chain.
    function _dispatch(bytes32 chainKey, uint256 validationId, bytes memory body) internal override {
        Token(_getTokenBound()).dispatchComplianceValidation(chainKey, validationId, body);
    }

    /// @inheritdoc TransferValidation
    function _settleOnToken(bytes memory from, bytes memory to, uint256 amount, uint256 validationId)
        internal
        override
    {
        _boundToken().settleValidation(from, to, amount, validationId);
    }

    /// @inheritdoc TransferValidation
    function _holdOnToken(bytes memory from, uint256 amount, uint256 validationId) internal override {
        _boundToken().holdInTransit(from, amount, validationId);
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

    function _removeModule(address _module) internal {
        require(_module != address(0), ErrorsLib.ZeroAddress());
        require(_getStorage().modules.remove(_module), ErrorsLib.ModuleNotBound());
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
