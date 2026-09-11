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

import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { ITransferValidation } from "./ITransferValidation.sol";

/**
 * @title TransferValidation
 * @dev The compliance's issuance layer for satellite movements: the settings, the per-chain pause, the record
 * of every issued validation, and the late-reconciliation surface.
 *
 * Storage sits in its own ERC-7201 namespace rather than in the compliance's, so the layer stays independently
 * reviewable, the module registry's layout is never disturbed by it, and the slot lifecycle can extend the same
 * namespace.
 *
 * Two deadlines with different meanings. `expiry` is the satellite's hard deadline: no execution at or after it.
 * `expiry + reconciliationWindow` is T-REX's release deadline: past it the slot may be released, but a
 * reconciliation arriving later is still recorded, flagged through `_onLateReconciliation`, and pauses the chain
 * it came from until the issuer explicitly unpauses it.
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

    // keccak256(abi.encode(uint256(keccak256("ERC3643.storage.TransferValidation")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant VALIDATION_STORAGE_LOCATION =
        0x65d3fdec06a1cc4685fac228d4975c3a0d37585c7963e3bcb1a5339b37cb1200;

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

    function _validationStorage() internal pure returns (ValidationStorage storage $) {
        assembly ("memory-safe") {
            $.slot := VALIDATION_STORAGE_LOCATION
        }
    }

}
