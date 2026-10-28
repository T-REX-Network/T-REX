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
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { IERC3643 } from "../../ERC-3643/IERC3643.sol";
import { IERC3643Compliance } from "../../ERC-3643/IERC3643Compliance.sol";
import { ERC3643Compliance } from "../../ERC-3643/base/ERC3643Compliance.sol";
import { ISettlementHandler } from "../../interop/ISettlementHandler.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { MessageTypesLib } from "../../libraries/MessageTypesLib.sol";
import { RolesLib } from "../../libraries/RolesLib.sol";
import { WalletKeyLib } from "../../libraries/WalletKeyLib.sol";
import { ITREXRegistry } from "../../registry/interface/ITREXRegistry.sol";
import { IToken } from "../../token/IToken.sol";
import { AccessManagedOwnableUpgradeable } from "../../utils/AccessManagedOwnableUpgradeable.sol";
import { IComplianceLedger } from "./IComplianceLedger.sol";
import { IModularCompliance } from "./IModularCompliance.sol";
import { ITransferValidation } from "./ITransferValidation.sol";
import { ModuleSetLib } from "./ModuleSetLib.sol";
import { MovementKindLib } from "./MovementKindLib.sol";
import { TransferContextLib } from "./TransferContextLib.sol";
import { TransferValidation } from "./TransferValidation.sol";
import { IModule } from "./modules/IModule.sol";

/// @title ModularCompliance
/// @dev {ERC3643Compliance} plus the module system that supplies the rules: the bound modules sorted by what
/// they are, the dispatch implementing the base hooks over the ledger, the `canSpenderCall` check, the
/// cross-chain validation lifecycle of {TransferValidation} and AccessManager authorization.
///
/// Every module reads the same numbers. On a movement the compliance resolves both identities once, asks every
/// `RULE` module the largest amount it allows and keeps the smallest answer, moves the positions, then tells
/// every `TRACKER` module what happened. A mint and a burn are the same movement with one side missing, so the
/// three base hooks differ only in which side they fill in. A module is kept in one list per type it named at
/// binding, so a dispatch is a plain loop over the modules concerned and nothing else.
contract ModularCompliance is
    IModularCompliance,
    ISettlementHandler,
    ERC3643Compliance,
    TransferValidation,
    AccessManagedOwnableUpgradeable
{

    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev The caller of the `transferFrom` the token is running. The ERC-3643 hooks carry no spender, so
    ///  {canSpenderCall}, which the token asks right before that transfer moves anything, writes it here for
    ///  the rules and trackers of the same transfer, and {_applyMovement} forgets it. Transient: it never
    ///  outlives the transaction and takes no storage slot.
    address private transient _transferFromSpender;

    constructor() {
        _disableInitializers();
    }

    function init(
        address tokenAddress,
        address accessManagerAddress,
        address[] calldata modules,
        bytes[] calldata moduleSettings
    ) external initializer {
        // `_bindToken` refuses a zero token with the same error, so only the manager is checked here.
        require(accessManagerAddress != address(0), ErrorsLib.ZeroAddress());
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
     *  @dev See {IModularCompliance-resyncModuleTypes}.
     *  Re-reads what the module says it is and files it again, as a rebind would, without touching the
     *  module's own state.
     */
    function resyncModuleTypes(address _module) external restricted {
        ModuleSetLib.resyncModuleTypes(_module);
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
     *  Every `SPENDER` module must agree. The context is built, and the wallets resolved, only when one is
     *  bound, so a token with no spender policy pays nothing here.
     */
    function canSpenderCall(address _spender, address _from, address _to, uint256 _value)
        external
        onlyBoundToken
        returns (bool)
    {
        _transferFromSpender = _spender;
        if (_moduleSet().byType[IModule.ModuleType.SPENDER].length() == 0) return true;
        return _spenderAllowed(_buildNativeContext(_from, _to, _value));
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
    function resolveStuckValidation(uint256 validationId) external restricted {
        _resolveStuckValidation(validationId);
    }

    /// @inheritdoc ITransferValidation
    /// @dev Not `restricted`: who may call depends on the clock. The keeper is recognised through the role the
    ///  AccessManager binds to this selector, and anyone else is admitted once the second window has passed.
    function discardExpiredValidations(uint256[] calldata validationIds) external {
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
    ///  claim a fresh compliance during setup), and the owner may always bind.
    ///
    ///  A token claiming the compliance must be one this compliance's AccessManager governs: it has given the
    ///  token's `setCompliance` a role. The caller writes its own `compliance()` and `authority()`, so neither
    ///  proves anything; only the manager's admin can configure a target, so any contract with no supply could
    ///  otherwise bind itself and write positions for any identity through a registry it chose.
    ///
    ///  The ledger keeps every position from the token's first mint and nothing seeds it, so the new token must
    ///  have no supply, and the token it replaces must be able to leave.
    function _authorizeTokenBinding(address token) internal view override {
        bool tokenClaimsUnboundCompliance = _getTokenBound() == address(0) && msg.sender == token;
        // A target the manager never configured answers the admin role, 0, for every selector.
        bool tokenGovernedByThisManager =
            IAccessManager(authority()).getTargetFunctionRole(token, IERC3643.setCompliance.selector) != 0;
        require(
            (tokenClaimsUnboundCompliance && tokenGovernedByThisManager) || _isOwner(msg.sender),
            ErrorsLib.OnlyOwnerOrTokenCanCall()
        );
        require(!_hasSupply(token), ErrorsLib.TokenCirculating());
        _requireBoundTokenCanLeave();
    }

    /// @dev Unbinding does not allow the "first bind" path: only the token itself or the owner, and only once
    ///  the token can leave.
    function _authorizeTokenUnbinding(address token) internal view override {
        require(msg.sender == token || _isOwner(msg.sender), ErrorsLib.OnlyOwnerOrTokenCanCall());
        _requireBoundTokenCanLeave();
    }

    /// @dev The ledger's positions belong to the bound token's holders, and no path binds a circulating token
    ///  back, so the token may leave only once it has no supply. An open validation keeps it too: closing one
    ///  releases its reservation on the bound token. A compliance that must change under it is upgraded instead.
    function _requireBoundTokenCanLeave() private view {
        require(!_hasSupply(_getTokenBound()), ErrorsLib.TokenCirculating());
        require(_ledger().pendingTotal == 0, ErrorsLib.ValidationsPending());
    }

    /* ----- The ERC-3643 hooks over the ledger ----- */

    /// @dev Rule evaluation: the amount must be at most the smallest amount any `RULE` module allows.
    ///  Nothing is resolved when no rule is bound.
    ///
    ///  A sender that resolves to no identity is refused outright while a rule is bound: it would read as a mint
    ///  and escape every rule about leaving. A holding wallet resolves to nobody only after the owner swaps the
    ///  registry's storage or unbinds a registry from it. The recipient needs no such guard, since the token asks
    ///  `isVerified` first, and that requires an active identity even with the eligibility checks disabled.
    function _canTransfer(address from, address to, uint256 value) internal view override returns (bool) {
        if (_moduleSet().byType[IModule.ModuleType.RULE].length() == 0) return true;
        IModule.TransferContext memory ctx = _buildNativeContext(from, to, value);
        if (from != address(0) && ctx.fromIdentity == address(0)) return false;
        return value <= _minAllowedAmount(ctx);
    }

    /// @dev A transfer: the position follows the tokens, then every `TRACKER` module is told.
    function _transferred(address from, address to, uint256 value) internal override {
        _applyMovement(from, to, value, MovementKindLib.TRANSFER);
    }

    /// @dev A mint: no sender, the recipient's position grows.
    function _created(address to, uint256 value) internal override {
        _applyMovement(address(0), to, value, MovementKindLib.MINT);
    }

    /// @dev A burn: no recipient, the sender's position shrinks.
    function _destroyed(address from, uint256 value) internal override {
        _applyMovement(from, address(0), value, MovementKindLib.BURN);
    }

    /// @dev See {IModularCompliance-syncOwner}. The owner change only, at adjustment zero: no movement is counted
    ///  and no module is told.
    function syncOwner(address wallet) external onlyBoundToken {
        _currentOwner(wallet, address(_boundRegistry().identity(wallet)), 0);
    }

    /// @dev See {IModularCompliance-agentTransferred}. Same guards as `transferred`, which this replaces on
    ///  the token's forced, recovery and delegation paths so that the trackers learn what moved the tokens.
    function agentTransferred(address from, address to, uint256 amount, uint8 kind) external onlyBoundToken {
        require(from != address(0) && to != address(0), ErrorsLib.ZeroAddress());
        require(amount > 0, ErrorsLib.ZeroValue());
        _applyMovement(from, to, amount, kind);
    }

    /// @dev Moves the positions and tells the trackers. One function serves all three hooks: the absent side of
    ///  a mint or a burn is a zero wallet and stays a zero identity. The context carries the kind the token
    ///  reported and the spender the rules were asked about, with each side's owner settled.
    ///
    ///  The hooks run after the token moved the balances, so each side's owner is settled with that already
    ///  applied: the sender's balance is what it holds now plus what just left, the recipient's what it holds now
    ///  minus what just arrived. A wallet whose owner changed since it was last credited has its balance moved
    ///  to the new owner here, before the movement itself is counted.
    ///
    ///  A self-transfer leaves the wallet's balance where it was, so neither side adds the value back: the
    ///  adjustment is the net effect on the wallet, zero when sender and recipient are the same. A delegation
    ///  also names the holder on both sides, but the token burned the amount before reporting it, so it keeps
    ///  the full adjustment.
    ///
    ///  The spender of a `transferFrom` is forgotten before the trackers run, so a transfer one of them makes
    ///  is not taken for it.
    function _applyMovement(address from, address to, uint256 value, uint8 kind) private {
        ITREXRegistry registry = _boundRegistry();
        address fromIdentity;
        address toIdentity;
        // A self-transfer leaves the balance where it was; a delegation reports holder to holder after its burn.
        bool balanceUnchanged = from == to && kind != MovementKindLib.DELEGATION;
        int256 adjustment = balanceUnchanged ? int256(0) : int256(value);
        if (from != address(0)) fromIdentity = _currentOwner(from, address(registry.identity(from)), adjustment);
        if (to != address(0)) toIdentity = _currentOwner(to, address(registry.identity(to)), -adjustment);

        IModule.TransferContext memory ctx = TransferContextLib.native(
            address(this), kind, fromIdentity, toIdentity, from, to, value, _transferFromSpenderEnvelope()
        );
        _transferFromSpender = address(0);
        _movePosition(ctx.fromIdentity, ctx.toIdentity, ctx.fromWallet, ctx.toWallet, ctx.amountMax);
        _callAfterTransfer(ctx);
    }

    /// @dev Resolves both wallets once, through the registry's native lookup, and builds the context of a
    ///  native movement. A zero wallet (the mint or burn side) stays a zero identity and a zero key. The
    ///  spender is the caller of the `transferFrom` in progress, empty on any other movement.
    function _buildNativeContext(address from, address to, uint256 value)
        private
        view
        returns (IModule.TransferContext memory)
    {
        ITREXRegistry registry = _boundRegistry();
        address fromIdentity;
        address toIdentity;
        if (from != address(0)) fromIdentity = address(registry.identity(from));
        if (to != address(0)) toIdentity = address(registry.identity(to));
        // Only a transfer or a mint is previewed: a burn asks no rule, and an agent's movement asks none either.
        uint8 kind = from == address(0) ? MovementKindLib.MINT : MovementKindLib.TRANSFER;
        return TransferContextLib.native(
            address(this), kind, fromIdentity, toIdentity, from, to, value, _transferFromSpenderEnvelope()
        );
    }

    /// @dev {_transferFromSpender} as the ERC-7930 envelope a module reads, empty when no `transferFrom` runs.
    function _transferFromSpenderEnvelope() private view returns (bytes memory) {
        if (_transferFromSpender == address(0)) return "";
        return InteroperableAddress.formatEvmV1(block.chainid, _transferFromSpender);
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
    function _spenderAllowed(IModule.TransferContext memory ctx) internal view override returns (bool) {
        EnumerableSet.AddressSet storage spenderRules = _moduleSet().byType[IModule.ModuleType.SPENDER];
        uint256 length = spenderRules.length();
        for (uint256 i = 0; i < length; i++) {
            if (!IModule(spenderRules.at(i)).moduleCheckSpender(ctx)) return false;
        }
        return true;
    }

    /// @inheritdoc TransferValidation
    function _callAfterTransfer(IModule.TransferContext memory ctx) internal override {
        EnumerableSet.AddressSet storage trackers = _moduleSet().byType[IModule.ModuleType.TRACKER];
        uint256 length = trackers.length();
        for (uint256 i = 0; i < length; i++) {
            IModule(trackers.at(i)).afterTransfer(ctx);
        }
    }

    /// @inheritdoc TransferValidation
    /// @dev The token is the wire's only author: it pins the route per leg and refuses a closed chain.
    function _dispatchLeg(bytes32 chainKey, uint256 validationId, bytes memory body) internal override {
        IToken(_getTokenBound()).dispatchComplianceValidation(chainKey, validationId, body);
    }

    /// @inheritdoc TransferValidation
    function _settleOnToken(bytes memory from, bytes memory to, uint256 amount, uint256 validationId)
        internal
        override
    {
        _boundToken().settleValidation(from, to, amount, validationId);
    }

    /// @inheritdoc TransferValidation
    function _holdOnToken(bytes memory from, uint256 amount, uint256 validationId, uint256 reserved) internal override {
        _boundToken().holdInTransit(from, amount, validationId, reserved);
    }

    /// @inheritdoc TransferValidation
    function _releaseOnToken(bytes memory wallet, uint256 amount) internal override {
        _boundToken().releaseFromValidation(wallet, amount);
    }

    /// @inheritdoc TransferValidation
    function _returnHeldOnToken(bytes memory to, uint256 validationId) internal override {
        _boundToken().returnHeldInTransit(to, validationId);
    }

    /* ----- Module lifecycle ----- */

    /// @dev Binds a module. No caller check: wrappers enforce it. See {ModuleSetLib-addModule}.
    function _addModule(address _module) internal {
        ModuleSetLib.addModule(_module);
    }

    /// @dev Takes a module out of every list it sits in, without calling into it.
    function _removeModule(address _module) internal {
        ModuleSetLib.removeModule(_module);
    }

    /// @dev Forwards `callData` to a bound `_module`. No caller check: wrappers enforce it.
    function _callModuleFunction(bytes calldata callData, address _module) internal {
        ModuleSetLib.callModuleFunction(callData, _module);
    }

    /// @dev An address with no code has no supply. A compliance is bound to the token's predicted address before
    ///  the token is deployed, and a spare compliance is prepared by binding a placeholder then unbinding it.
    function _hasSupply(address token) private view returns (bool) {
        return token.code.length != 0 && IToken(token).totalSupply() != 0;
    }

    function _isOwner(address caller) internal view returns (bool) {
        (bool isOwner,) =
            AuthorityUtils.canCallWithDelay(authority(), caller, address(this), RolesLib.BIND_UNBIND_TOKEN);
        return isOwner;
    }

    function _moduleSet() private pure returns (ModuleSetLib.ModuleSet storage) {
        return ModuleSetLib.layout();
    }

}
