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
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { IERC3643Compliance } from "../../ERC-3643/IERC3643Compliance.sol";
import { ERC3643Compliance } from "../../ERC-3643/base/ERC3643Compliance.sol";
import { ISettlementHandler } from "../../interop/ISettlementHandler.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { MessageTypesLib } from "../../libraries/MessageTypesLib.sol";
import { RolesLib } from "../../libraries/RolesLib.sol";
import { ITREXRegistry } from "../../registry/interface/ITREXRegistry.sol";
import { IToken } from "../../token/IToken.sol";
import { Token } from "../../token/Token.sol";
import { AccessManagedOwnableUpgradeable } from "../../utils/AccessManagedOwnableUpgradeable.sol";
import { IComplianceLedger } from "./IComplianceLedger.sol";
import { IModularCompliance } from "./IModularCompliance.sol";
import { ITransferValidation } from "./ITransferValidation.sol";
import { TransferValidation } from "./TransferValidation.sol";
import { IModule } from "./modules/IModule.sol";

/// @title ModularCompliance
/// @dev {ERC3643Compliance} plus the module system that supplies the rules: the bound modules sorted by what
/// they are, the dispatch implementing the base hooks over the ledger, the `canSpenderCall` check, the
/// cross-chain validation lifecycle of {TransferValidation} and AccessManager authorization.
///
/// Every module reads the same numbers. On a movement the compliance resolves both identities once, asks every
/// `RULE` module the largest amount it allows and keeps the smallest answer, moves the positions, then tells
/// every `TRACKER` module what happened. A module is kept in one list per type it named at binding, so a
/// dispatch is a plain loop over the modules concerned and nothing else.
contract ModularCompliance is
    IModularCompliance,
    ISettlementHandler,
    ERC3643Compliance,
    TransferValidation,
    AccessManagedOwnableUpgradeable
{

    using EnumerableSet for EnumerableSet.AddressSet;

    /// @custom:storage-location erc7201:erc3643.storage.TREXCompliance
    /// @dev One list of every bound module, plus one list per type. A module sits in `modules` and in the
    ///  list of each type it named, so every dispatch is a loop over exactly the modules that answer it.
    ///  Keying the lists by the type rather than naming one field each means a type added later needs a new
    ///  enum member and its dispatch, and nothing else here.
    struct ModuleSet {
        /// Every bound module, at most 25. What `getModules` returns.
        EnumerableSet.AddressSet modules;
        /// The modules of each type, in the order they were bound.
        mapping(IModule.ModuleType moduleType => EnumerableSet.AddressSet) byType;
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
     *  A writer is refused here too: `removeKeyWriter` needs no call into the module, so it comes first.
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
     *  @dev See {IModularCompliance-resyncModuleTypes}.
     *  Re-reads what the module says it is and files it again, as a rebind would, without touching the
     *  module's own state.
     */
    function resyncModuleTypes(address _module) external restricted {
        ModuleSet storage moduleSet = _moduleSet();
        require(moduleSet.modules.contains(_module), ErrorsLib.ModuleNotBound());
        _removeFromItsTypeLists(moduleSet, _module);
        _addToItsTypeLists(moduleSet, _module);
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
        return _moduleSet().modules.contains(_module);
    }

    /**
     *  @dev See {IModularCompliance-getModules}.
     */
    function getModules() external view returns (address[] memory) {
        return _moduleSet().modules.values();
    }

    /**
     *  @dev See {IModularCompliance-getModulesByType}.
     */
    function getModulesByType(IModule.ModuleType moduleType) external view returns (address[] memory) {
        return _moduleSet().byType[moduleType].values();
    }

    /**
     *  @dev See {IModularCompliance-canSpenderCall}.
     *  Every `SPENDER` module must agree. Wallets are passed as the token knows them: a spender policy is
     *  about who calls, not about how the asset is distributed, so nothing is resolved here.
     */
    function canSpenderCall(address _spender, address _from, address _to, uint256 _value) external view returns (bool) {
        EnumerableSet.AddressSet storage spenderRules = _moduleSet().byType[IModule.ModuleType.SPENDER];
        uint256 length = spenderRules.length();
        for (uint256 i = 0; i < length; i++) {
            if (!IModule(spenderRules.at(i)).moduleCheckSpender(_spender, _from, _to, _value, address(this))) {
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
    function setIssuancePaused(bytes32 chainKey, bool paused) external restricted {
        _setIssuancePaused(chainKey, paused);
    }

    /// @inheritdoc ITransferValidation
    function discardExpiredValidations(uint256[] calldata validationIds) external restricted {
        _discardExpiredValidations(validationIds);
    }

    /**
     *  @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IModularCompliance).interfaceId
            || interfaceId == type(IERC3643Compliance).interfaceId
            || interfaceId == type(ISettlementHandler).interfaceId
            || interfaceId == type(ITransferValidation).interfaceId
            || interfaceId == type(IComplianceLedger).interfaceId || super.supportsInterface(interfaceId);
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

    /* ----- The ERC-3643 hooks over the ledger ----- */

    /// @dev Rule evaluation: the amount must be at most the smallest amount any `RULE` module allows.
    ///  Nothing is resolved when no rule is bound.
    function _canTransfer(address from, address to, uint256 value) internal view override returns (bool) {
        if (_moduleSet().byType[IModule.ModuleType.RULE].length() == 0) return true;
        return value <= _minAllowedAmount(_buildNativeContext(from, to, value));
    }

    /// @dev A transfer: the position follows the tokens, then every `TRACKER` module is told.
    function _transferred(address from, address to, uint256 value) internal override {
        IModule.TransferContext memory ctx = _buildNativeContext(from, to, value);
        _movePosition(ctx.fromIdentity, ctx.toIdentity, ctx.fromWallet, ctx.toWallet, value);
        _callTransferAction(ctx, value);
    }

    /// @dev A mint: no sender, the recipient's position grows.
    function _created(address to, uint256 value) internal override {
        IModule.TransferContext memory ctx = _buildNativeContext(address(0), to, value);
        _movePosition(address(0), ctx.toIdentity, bytes32(0), ctx.toWallet, value);
        EnumerableSet.AddressSet storage trackers = _moduleSet().byType[IModule.ModuleType.TRACKER];
        uint256 length = trackers.length();
        for (uint256 i = 0; i < length; i++) {
            IModule(trackers.at(i)).moduleMintAction(ctx, value);
        }
    }

    /// @dev A burn: no recipient, the sender's position shrinks.
    function _destroyed(address from, uint256 value) internal override {
        IModule.TransferContext memory ctx = _buildNativeContext(from, address(0), value);
        _movePosition(ctx.fromIdentity, address(0), ctx.fromWallet, bytes32(0), value);
        EnumerableSet.AddressSet storage trackers = _moduleSet().byType[IModule.ModuleType.TRACKER];
        uint256 length = trackers.length();
        for (uint256 i = 0; i < length; i++) {
            IModule(trackers.at(i)).moduleBurnAction(ctx, value);
        }
    }

    /// @dev Resolves both wallets once, through the registry's native lookup, and builds the context of a
    ///  native movement. A zero wallet (the mint or burn side) stays a zero identity and a zero key.
    function _buildNativeContext(address from, address to, uint256 value)
        private
        view
        returns (IModule.TransferContext memory ctx)
    {
        ITREXRegistry registry = _boundRegistry();
        ctx.compliance = address(this);
        if (from != address(0)) {
            ctx.fromIdentity = address(registry.identity(from));
            ctx.fromWallet = _walletKeyOf(from);
        }
        if (to != address(0)) {
            ctx.toIdentity = address(registry.identity(to));
            ctx.toWallet = _walletKeyOf(to);
        }
        ctx.amountMin = value;
        ctx.amountMax = value;
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
    /// @dev The smallest answer of the `RULE` modules. `allowedAmount` is a view on the interface, so each
    ///  call is a `staticcall` and a module that writes there reverts.
    function _minAllowedAmount(IModule.TransferContext memory ctx) internal view override returns (uint256 allowed) {
        allowed = type(uint256).max;
        EnumerableSet.AddressSet storage rules = _moduleSet().byType[IModule.ModuleType.RULE];
        uint256 length = rules.length();
        for (uint256 i = 0; i < length; i++) {
            uint256 answer = IModule(rules.at(i)).allowedAmount(ctx);
            if (answer < allowed) allowed = answer;
        }
    }

    /// @inheritdoc TransferValidation
    function _callTransferAction(IModule.TransferContext memory ctx, uint256 amount) internal override {
        EnumerableSet.AddressSet storage trackers = _moduleSet().byType[IModule.ModuleType.TRACKER];
        uint256 length = trackers.length();
        for (uint256 i = 0; i < length; i++) {
            IModule(trackers.at(i)).moduleTransferAction(ctx, amount);
        }
    }

    /// @inheritdoc TransferValidation
    /// @dev The token is the wire's only author: it pins the route per leg and refuses a closed chain.
    function _dispatchLeg(bytes32 chainKey, uint256 validationId, bytes memory body) internal override {
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

    /* ----- Module lifecycle ----- */

    /// @dev Binds a module: zero check, duplicate check, cap of 25, plug-and-play / canComplianceBind
    ///  requirement, then it is sorted into the list of every type it names. No caller check — wrappers
    ///  enforce it. Everything is validated before any state is written, so `canComplianceBind` sees the
    ///  module as not yet bound.
    function _addModule(address _module) internal {
        require(_module != address(0), ErrorsLib.ZeroAddress());
        ModuleSet storage moduleSet = _moduleSet();
        require(moduleSet.modules.length() < 25, ErrorsLib.MaxModulesReached(25));
        require(!moduleSet.modules.contains(_module), ErrorsLib.ModuleAlreadyBound());
        IModule module = IModule(_module);
        require(
            module.isPlugAndPlay() || module.canComplianceBind(address(this)),
            ErrorsLib.ComplianceNotSuitableForBindingToModule(_module)
        );

        moduleSet.modules.add(_module);
        _addToItsTypeLists(moduleSet, _module);

        module.bindCompliance(address(this));

        emit EventsLib.ModuleAdded(_module);
    }

    /// @dev Takes a module out of every list it sits in, without calling into it.
    function _removeModule(address _module) internal {
        require(_module != address(0), ErrorsLib.ZeroAddress());
        ModuleSet storage moduleSet = _moduleSet();
        require(moduleSet.modules.remove(_module), ErrorsLib.ModuleNotBound());
        _removeFromItsTypeLists(moduleSet, _module);
    }

    /// @dev Adds the module to the list of every type it names. A module that names nothing would never be
    ///  called, and one that names a type twice has a declaration its author did not mean; both are refused.
    function _addToItsTypeLists(ModuleSet storage moduleSet, address _module) private {
        IModule.ModuleType[] memory moduleTypes = IModule(_module).moduleTypes();
        require(moduleTypes.length != 0, ErrorsLib.ModuleHasNoType());

        for (uint256 i = 0; i < moduleTypes.length; i++) {
            IModule.ModuleType moduleType = moduleTypes[i];
            require(moduleSet.byType[moduleType].add(_module), ErrorsLib.DuplicateModuleType(uint8(moduleType)));
        }

        emit EventsLib.ModuleTypesRecorded(_module, moduleTypes);
    }

    /// @dev Removes the module from the list of every type, whichever ones it was in. It walks all the types
    ///  rather than asking the module what it names now, so a module whose declaration changed since it was
    ///  bound still leaves the lists it really sits in.
    function _removeFromItsTypeLists(ModuleSet storage moduleSet, address _module) private {
        for (uint256 i = 0; i <= uint256(type(IModule.ModuleType).max); i++) {
            moduleSet.byType[IModule.ModuleType(i)].remove(_module);
        }
    }

    /// @dev Forwards `callData` to a bound `_module` via low-level call and emits the interaction event.
    ///  Reverts when `_module` is not bound or when the underlying call fails. No caller check — wrappers enforce it.
    function _callModuleFunction(bytes calldata callData, address _module) internal {
        require(_moduleSet().modules.contains(_module), ErrorsLib.ModuleNotBound());

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

    function _moduleSet() private pure returns (ModuleSet storage moduleSet) {
        assembly ("memory-safe") {
            moduleSet.slot := STORAGE_LOCATION
        }
    }

}
