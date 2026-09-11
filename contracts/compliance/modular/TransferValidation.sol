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

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";

import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { MessageTypesLib } from "../../libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "../../libraries/WalletKeyLib.sol";
import { ITREXRegistry } from "../../registry/interface/ITREXRegistry.sol";
import { IToken } from "../../token/IToken.sol";
import { ITransferValidation } from "./ITransferValidation.sol";

/**
 * @title TransferValidation
 * @dev The compliance's issuance layer for satellite movements: settings, per-chain pause, the record of every
 * issued validation, the issuance itself, and the late-reconciliation surface. Own ERC-7201 namespace, so the
 * module registry's layout is untouched and the slot lifecycle can extend it.
 *
 * Issuance never widens what was asked: the request is capped at the sender's balance, narrowed by every `BOUNDS`
 * module, then clamped. The balance cap is a firewall: a validation can never authorize more than the register
 * recorded, so tokens created out of nothing on a satellite can never obtain one. `expiry` is the satellite's hard
 * deadline; `expiry + reconciliationWindow` is when T-REX may release the slot, never a refusal of a late leg.
 */
abstract contract TransferValidation is ITransferValidation {

    /// @custom:storage-location erc7201:ERC3643.storage.TransferValidation
    struct ValidationStorage {
        /// Added to the issuance timestamp to compute `expiry`. Zero blocks issuance.
        uint64 defaultValidityWindow;
        /// Ceiling on `amountMax`, applied last. Zero means none.
        uint256 validationClamp;
        /// Per-chain worst-case reconciliation latency. Zero blocks issuance toward that chain.
        mapping(bytes32 chainKey => uint64 window) reconciliationWindows;
        /// Per-chain issuance pause, set by the manager or a late reconciliation, lifted by the manager only.
        mapping(bytes32 chainKey => bool paused) issuancePaused;
        /// The last id issued. Ids start at 1.
        uint256 nextValidationId;
        /// What the slot lifecycle keys on.
        mapping(uint256 validationId => ValidationRecord record) validations;
    }

    /// @dev Both sides of a movement, parsed once. Native means a non-zero EVM address on this chain.
    struct Legs {
        bool fromNative;
        address fromWallet;
        bytes32 fromChainKey;
        bool toNative;
        bytes32 toChainKey;
    }

    // keccak256(abi.encode(uint256(keccak256("ERC3643.storage.TransferValidation")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant VALIDATION_STORAGE_LOCATION =
        0x65d3fdec06a1cc4685fac228d4975c3a0d37585c7963e3bcb1a5339b37cb1200;

    /// @inheritdoc ITransferValidation
    function requestTransferValidation(
        bytes calldata from,
        bytes calldata to,
        uint256 requestedMin,
        uint256 requestedMax,
        bytes calldata spender
    ) external returns (uint256 validationId) {
        require(requestedMin <= requestedMax, ErrorsLib.InvalidRequestedRange(requestedMin, requestedMax));
        if (spender.length != 0) WalletKeyLib.parse(spender);
        Legs memory legs = _legsOf(from, to);
        _authorize(msg.sender, from, legs);

        // Built once; the bounds are refined in place, then the id is assigned.
        MessageTypesLib.ComplianceValidation memory validation;
        validation.from = from;
        validation.to = to;
        validation.spender = spender;
        validation.amountMin = requestedMin;
        validation.amountMax = requestedMax;
        validation.token = address(_boundToken());
        _fill(validation, legs);

        validationId = _issue(validation, legs);
    }

    /// @inheritdoc ITransferValidation
    function defaultValidityWindow() public view returns (uint64) {
        return _validationStorage().defaultValidityWindow;
    }

    /// @inheritdoc ITransferValidation
    function reconciliationWindowOf(bytes32 chainKey) public view returns (uint64) {
        return _validationStorage().reconciliationWindows[chainKey];
    }

    /// @inheritdoc ITransferValidation
    function validationClamp() public view returns (uint256) {
        return _validationStorage().validationClamp;
    }

    /// @inheritdoc ITransferValidation
    function isIssuancePaused(bytes32 chainKey) public view returns (bool) {
        return _validationStorage().issuancePaused[chainKey];
    }

    /// @inheritdoc ITransferValidation
    function nextValidationId() public view returns (uint256) {
        return _validationStorage().nextValidationId;
    }

    /// @inheritdoc ITransferValidation
    function validationOf(uint256 validationId) public view returns (ValidationRecord memory) {
        return _validationStorage().validations[validationId];
    }

    /* ----- What the compliance provides ----- */

    /// @dev The token this compliance is bound to.
    function _boundToken() internal view virtual returns (IToken);

    /// @dev The registry of the bound token.
    function _boundRegistry() internal view virtual returns (ITREXRegistry);

    /// @dev Whether the AccessManager lets `caller` call `selector` on this contract now.
    function _canCallSelector(address caller, bytes4 selector) internal view virtual returns (bool);

    /// @dev Narrows the running range by intersection through every module that declared `BOUNDS`.
    function _moduleBounds(bytes memory from, bytes memory to, uint256 currentMin, uint256 currentMax)
        internal
        view
        virtual
        returns (uint256 min, uint256 max);

    /// @dev Reserves the compliance slots of a validation being issued. Empty until the slot lifecycle fills it.
    function _reserveSlots(uint256 validationId, bytes memory from, bytes memory to, uint256 amountMax)
        internal
        virtual { }

    /// @dev Sends one leg of a validation toward `chainKey`, through the token.
    function _dispatch(bytes32 chainKey, uint256 validationId, bytes memory body) internal virtual;

    /* ----- Settings ----- */

    function _setDefaultValidityWindow(uint64 duration) internal {
        require(duration != 0, ErrorsLib.ZeroDuration());
        _validationStorage().defaultValidityWindow = duration;
        emit EventsLib.DefaultValidityWindowSet(duration);
    }

    function _setReconciliationWindow(bytes32 chainKey, uint64 duration) internal {
        require(duration != 0, ErrorsLib.ZeroDuration());
        _validationStorage().reconciliationWindows[chainKey] = duration;
        emit EventsLib.ReconciliationWindowSet(chainKey, duration);
    }

    /// @dev Zero clears the clamp, so no zero check here.
    function _setValidationClamp(uint256 maxAmount) internal {
        _validationStorage().validationClamp = maxAmount;
        emit EventsLib.ValidationClampSet(maxAmount);
    }

    function _pauseIssuance(bytes32 chainKey) internal {
        ValidationStorage storage s = _validationStorage();
        require(!s.issuancePaused[chainKey], ErrorsLib.ValidationIssuancePaused(chainKey));
        s.issuancePaused[chainKey] = true;
        emit EventsLib.ValidationIssuancePaused(chainKey);
    }

    function _unpauseIssuance(bytes32 chainKey) internal {
        ValidationStorage storage s = _validationStorage();
        require(s.issuancePaused[chainKey], ErrorsLib.ValidationIssuanceNotPaused(chainKey));
        s.issuancePaused[chainKey] = false;
        emit EventsLib.ValidationIssuanceUnpaused(chainKey);
    }

    /// @dev A settlement of `validationId` arrived from `chainKey` after `releaseAt`. The slot lifecycle records it
    ///  and calls this: a warning, and the chain paused until the issuer explicitly unpauses. Never reverts.
    function _onLateReconciliation(uint256 validationId, bytes32 chainKey) internal {
        emit EventsLib.LateReconciliation(validationId, chainKey);
        ValidationStorage storage s = _validationStorage();
        if (!s.issuancePaused[chainKey]) {
            s.issuancePaused[chainKey] = true;
            emit EventsLib.ValidationIssuancePaused(chainKey);
        }
    }

    /* ----- Issuance steps ----- */

    /// @dev Parses both envelopes. A movement with no satellite side has nothing to dispatch.
    function _legsOf(bytes calldata from, bytes calldata to) private view returns (Legs memory legs) {
        (legs.fromNative, legs.fromWallet) = WalletKeyLib.isReferenceChain(from);
        legs.fromChainKey = _chainKeyOf(from);
        (legs.toNative,) = WalletKeyLib.isReferenceChain(to);
        legs.toChainKey = _chainKeyOf(to);
        require(!legs.fromNative || !legs.toNative, ErrorsLib.NoSatelliteLeg());
    }

    function _chainKeyOf(bytes calldata wallet) private pure returns (bytes32) {
        (bytes2 chainType, bytes memory chainReference,) = WalletKeyLib.parse(wallet);
        return MessageTypesLib.chainKey(chainType, chainReference);
    }

    /// @dev `from` itself when native, the identity it is linked to, or a caller the AccessManager authorises.
    ///  A satellite wallet never matches its own bytes: a caller proves control of a key here, not elsewhere.
    function _authorize(address caller, bytes calldata from, Legs memory legs) private view {
        if (legs.fromNative && caller == legs.fromWallet) return;
        IIdentity fromIdentity = _boundRegistry().resolveIdentity(from);
        if (address(fromIdentity) != address(0) && caller == address(fromIdentity)) return;
        require(
            _canCallSelector(caller, this.requestTransferValidation.selector),
            ErrorsLib.NotAuthorizedForWallet(caller, from)
        );
    }

    /// @dev The larger window of the involved satellite chains, each of which must be open and configured.
    function _windowOf(ValidationStorage storage s, Legs memory legs) private view returns (uint64 window) {
        require(s.defaultValidityWindow != 0, ErrorsLib.ValidityWindowNotSet());
        if (!legs.fromNative) window = _chainWindow(s, legs.fromChainKey);
        if (!legs.toNative && (legs.fromNative || legs.toChainKey != legs.fromChainKey)) {
            uint64 toWindow = _chainWindow(s, legs.toChainKey);
            if (toWindow > window) window = toWindow;
        }
    }

    function _chainWindow(ValidationStorage storage s, bytes32 chainKey) private view returns (uint64 window) {
        require(!s.issuancePaused[chainKey], ErrorsLib.ValidationIssuancePaused(chainKey));
        window = s.reconciliationWindows[chainKey];
        require(window != 0, ErrorsLib.ReconciliationWindowNotSet(chainKey));
    }

    /// @dev Deadlines, then bounds, written into the validation in place.
    function _fill(MessageTypesLib.ComplianceValidation memory validation, Legs memory legs) private view {
        ValidationStorage storage s = _validationStorage();
        validation.reconciliationWindow = _windowOf(s, legs);
        validation.expiry = uint64(block.timestamp) + s.defaultValidityWindow;
        (validation.amountMin, validation.amountMax) = _bounds(s, validation, legs);
    }

    /// @dev Eligibility, then the bounds: the request capped at `from`'s balance, narrowed by the modules unless
    ///  both sides belong to one identity, clamped last. An empty or zero range is refused before any write.
    function _bounds(
        ValidationStorage storage s,
        MessageTypesLib.ComplianceValidation memory validation,
        Legs memory legs
    ) private view returns (uint256 min, uint256 max) {
        ITREXRegistry registry = _boundRegistry();
        IIdentity fromIdentity = registry.resolveIdentity(validation.from);
        require(address(fromIdentity) != address(0), ErrorsLib.UnverifiedWallet(validation.from));
        require(registry.isWalletVerified(validation.to), ErrorsLib.UnverifiedWallet(validation.to));

        uint256 balance = legs.fromNative
            ? _boundToken().freeBalanceOf(legs.fromWallet)
            : _boundToken().bridgedBalanceOf(validation.from);
        min = validation.amountMin;
        max = validation.amountMax < balance ? validation.amountMax : balance;
        require(min <= max, ErrorsLib.EmptyValidationRange(min, max));

        if (fromIdentity != registry.resolveIdentity(validation.to)) {
            (min, max) = _moduleBounds(validation.from, validation.to, min, max);
        }
        uint256 clamp = s.validationClamp;
        if (clamp != 0 && clamp < max) max = clamp;
        require(min <= max, ErrorsLib.EmptyValidationRange(min, max));
        require(max != 0, ErrorsLib.ZeroValue());
    }

    /// @dev Assigns the id, stores the record, reserves the slots, announces, dispatches. The first write.
    function _issue(MessageTypesLib.ComplianceValidation memory validation, Legs memory legs)
        private
        returns (uint256 validationId)
    {
        ValidationStorage storage s = _validationStorage();
        validationId = ++s.nextValidationId;
        validation.validationId = validationId;
        _record(s, validation, legs);
        _reserveSlots(validationId, validation.from, validation.to, validation.amountMax);

        emit EventsLib.TransferValidationIssued(
            validationId,
            validation.from,
            validation.to,
            validation.spender,
            validation.amountMin,
            validation.amountMax,
            validation.expiry,
            validation.reconciliationWindow
        );
        _dispatchLegs(legs, validation);
    }

    function _record(
        ValidationStorage storage s,
        MessageTypesLib.ComplianceValidation memory validation,
        Legs memory legs
    ) private {
        s.validations[validation.validationId] = ValidationRecord({
            hash: MessageTypesLib.hashValidation(validation),
            amountMin: validation.amountMin,
            amountMax: validation.amountMax,
            expiry: validation.expiry,
            releaseAt: validation.expiry + validation.reconciliationWindow,
            fromChainKey: legs.fromChainKey,
            toChainKey: legs.toChainKey
        });
    }

    /// @dev One leg per distinct satellite chain, under the same id.
    function _dispatchLegs(Legs memory legs, MessageTypesLib.ComplianceValidation memory validation) private {
        bytes memory body = abi.encode(validation);
        if (!legs.fromNative) _dispatch(legs.fromChainKey, validation.validationId, body);
        if (!legs.toNative && (legs.fromNative || legs.toChainKey != legs.fromChainKey)) {
            _dispatch(legs.toChainKey, validation.validationId, body);
        }
    }

    function _validationStorage() internal pure returns (ValidationStorage storage $) {
        assembly ("memory-safe") {
            $.slot := VALIDATION_STORAGE_LOCATION
        }
    }

}
