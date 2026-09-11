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
 * @dev The compliance's issuance layer for satellite movements: the settings, the per-chain pause, the record
 * of every issued validation, the issuance itself, and the late-reconciliation surface.
 *
 * Storage sits in its own ERC-7201 namespace rather than in the compliance's, so the layer stays independently
 * reviewable, the module registry's layout is never disturbed by it, and the slot lifecycle can extend the same
 * namespace.
 *
 * Issuance never widens what was asked. The requested range is capped at the sender's balance on its chain, then
 * every module declaring `BOUNDS` narrows it by intersection, then the clamp applies; an empty range reverts
 * before anything is written. The balance cap is a firewall, not a convenience: a validation can never authorize
 * more than the register has recorded, so tokens created out of nothing on a satellite can never obtain one.
 *
 * Two deadlines with different meanings. `expiry` is the satellite's hard deadline: no execution at or after it.
 * `expiry + reconciliationWindow` is T-REX's release deadline: past it the slot may be released, but a
 * reconciliation arriving later is still recorded, flagged through `_onLateReconciliation`, and pauses the chain
 * it came from until the issuer explicitly unpauses it.
 *
 * What the compliance provides is left abstract: the token and registry it is bound to, the AccessManager check,
 * the module dispatch, the slot reservation the lifecycle will fill, and the dispatch through the token.
 */
abstract contract TransferValidation is ITransferValidation {

    /// @custom:storage-location erc7201:ERC3643.storage.TransferValidation
    struct ValidationStorage {
        /// Added to the issuance timestamp to compute `expiry`. Zero blocks issuance.
        uint64 defaultValidityWindow;
        /// Optional ceiling on `amountMax`, applied after the modules. Zero means none.
        uint256 validationClamp;
        /// Per-chain worst-case reconciliation latency. A chain with none configured cannot be issued for.
        mapping(bytes32 chainKey => uint64 window) reconciliationWindows;
        /// Per-chain issuance pause, set by the manager or by a late reconciliation, lifted by the manager only.
        mapping(bytes32 chainKey => bool paused) issuancePaused;
        /// The last id issued. Ids start at 1.
        uint256 nextValidationId;
        /// What the slot lifecycle keys on, per issued validation.
        mapping(uint256 validationId => ValidationRecord record) validations;
    }

    /// @dev The two sides of a movement, parsed once. A side is native when its envelope designates a non-zero
    ///  EVM address on this chain; its key is then the reference chain's own.
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
        Legs memory legs = _legsOf(from, to);
        _authorize(msg.sender, from, legs);

        // Built once and passed around: the bounds are refined in place, then the id is assigned.
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

    /// @dev Whether the AccessManager lets `caller` call `selector` on this contract right now.
    function _canCallSelector(address caller, bytes4 selector) internal view virtual returns (bool);

    /// @dev Narrows the running range through every bound module that declared `BOUNDS`, by intersection.
    function _moduleBounds(bytes memory from, bytes memory to, uint256 currentMin, uint256 currentMax)
        internal
        view
        virtual
        returns (uint256 min, uint256 max);

    /// @dev Reserves the compliance slots of a validation being issued. The slot lifecycle fills it; until then a
    ///  validation is issued and recorded without any reservation.
    function _reserveSlots(uint256 validationId, bytes memory from, bytes memory to, uint256 amountMax)
        internal
        virtual { }

    /// @dev Sends one leg of a validation to the token's peer on `chainKey`, through the token.
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

    /// @dev The late-reconciliation surface: a settlement of `validationId` arrived from `chainKey` after
    ///  `releaseAt`. The settlement itself is recorded by the slot lifecycle, which calls this; here the exception
    ///  is made loud and bounded: a warning event, and the chain's issuance paused until the issuer has resolved
    ///  the exception and explicitly unpaused. Never reverts, so a final satellite settlement is never refused.
    function _onLateReconciliation(uint256 validationId, bytes32 chainKey) internal {
        emit EventsLib.LateReconciliation(validationId, chainKey);
        ValidationStorage storage s = _validationStorage();
        if (!s.issuancePaused[chainKey]) {
            s.issuancePaused[chainKey] = true;
            emit EventsLib.ValidationIssuancePaused(chainKey);
        }
    }

    /* ----- Issuance steps ----- */

    /// @dev Parses both envelopes once. Refuses a movement with no satellite side: there would be nothing to
    ///  dispatch, and the native transfer path already applies.
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

    /// @dev Who may move `from`'s position: the wallet itself when it lives on this chain, the identity it is
    ///  linked to, or a caller the AccessManager authorises for this selector. A satellite wallet never matches its
    ///  own account bytes: a caller here proves control of a key on this chain, not of an account elsewhere.
    function _authorize(address caller, bytes calldata from, Legs memory legs) private view {
        if (legs.fromNative && caller == legs.fromWallet) return;
        IIdentity fromIdentity = _boundRegistry().resolveIdentity(from);
        if (address(fromIdentity) != address(0) && caller == address(fromIdentity)) return;
        require(
            _canCallSelector(caller, this.requestTransferValidation.selector),
            ErrorsLib.NotAuthorizedForWallet(caller, from)
        );
    }

    /// @dev The reconciliation window to snapshot: the larger of the involved satellite chains' windows, since
    ///  T-REX waits for both legs. Every involved satellite chain must be open for issuance and configured.
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

    /// @dev The deadlines, then the bounds, written into the validation in place.
    function _fill(MessageTypesLib.ComplianceValidation memory validation, Legs memory legs) private view {
        ValidationStorage storage s = _validationStorage();
        validation.reconciliationWindow = _windowOf(s, legs);
        validation.expiry = uint64(block.timestamp) + s.defaultValidityWindow;
        (validation.amountMin, validation.amountMax) = _bounds(s, validation, legs);
    }

    /// @dev Eligibility, then the bounds engine. `from` must own its position (revoked included), `to` must be
    ///  admitted as a local transfer would admit it. The range starts at the request capped at `from`'s balance on
    ///  its chain, skips the modules when both sides belong to one identity (not a change of ownership), is
    ///  narrowed by every bounds module otherwise, and takes the clamp last. Empty means refused, nothing written.
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
    }

    /// @dev Assigns the id, stores the record, reserves the slots, announces, dispatches. Nothing before this
    ///  point wrote anything.
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

    /// @dev One leg per distinct satellite chain, under the same id: to `to`'s chain when `from` is native, to
    ///  `from`'s chain when `to` is native or shares it, to both otherwise.
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
