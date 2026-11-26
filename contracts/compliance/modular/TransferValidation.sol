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

// T-REX Smart Contracts
// The ERC-3643 token suite of the T-REX ecosystem.
//
// Copyright (C) 2026 Digital Asset Operational Services ISAC Ltd. ("T-REX Network")
//
// This file is part of the T-REX smart contract suite.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
pragma solidity 0.8.30;

import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { IToken } from "../../token/IToken.sol";
import { ComplianceLedger } from "./ComplianceLedger.sol";
import { ITransferValidation } from "./ITransferValidation.sol";
import { TransferValidationLib } from "./TransferValidationLib.sol";

/**
 * @title TransferValidation
 * @dev The compliance's issuance layer for satellite movements: the two windows, the per-chain pause, the record
 * of every issued validation, the issuance itself, the pending reservation it writes, settlement, discard and the
 * late-reconciliation surface. Own ERC-7201 namespace, so the module registry's layout is untouched.
 *
 * Three flows, each readable top to bottom, each in a library deployed once and linked so the compliance stays
 * under the contract size limit: {TransferValidationLib-request} issues, {TransferSettlementLib-handleSettlement}
 * applies what a satellite executed, {TransferSettlementLib-discardExpiredValidations} rolls back what it never
 * did. What stays here is the entry points of the first, the views and the settings. The reservation involves no
 * module: issuance writes the pending amounts into the ledger and the other two flows release them once.
 *
 * `from` is always a satellite wallet, never a native one: the Lite that executes a validation has to physically
 * hold the position it moves, where a native balance stays free to leave between issuance and settlement. A native
 * position reaches a satellite through delegation-out instead, which burns before it instructs.
 *
 * `expiry` is the satellite's hard deadline; `expiry + reconciliationWindow` is when T-REX may release the
 * reservation, never a refusal of a late leg. Validations expire; settlements never do.
 */
abstract contract TransferValidation is ITransferValidation, ComplianceLedger {

    /* ----- Issuance ----- */

    /// @inheritdoc ITransferValidation
    /// @dev The questions asked before anything is written, and the issuance, live in
    ///  {TransferValidationLib-request}.
    function requestTransferValidation(
        bytes calldata from,
        bytes calldata to,
        uint256 requestedMin,
        uint256 requestedMax,
        bytes calldata spender
    ) external returns (uint256 validationId) {
        return TransferValidationLib.request(
            from, to, requestedMin, requestedMax, spender, address(_boundToken()), _authority()
        );
    }

    /// @inheritdoc ITransferValidation
    /// @dev The answer, the narrowing and the legs live in {TransferValidationLib-answerApproval}.
    function answerApproval(uint256 validationId, uint256 approvedMax) external {
        TransferValidationLib.answerApproval(validationId, approvedMax, address(_boundToken()));
    }

    /// @inheritdoc ITransferValidation
    /// @dev The record does not keep `to`, which the caller supplies again with `spender`; the rebuilt leg
    ///  must hash to what was issued, see {TransferValidationLib-resend}. Nothing is written: the
    ///  reservation, the id and the pinned route are those of the issuance, and the token refuses the send once
    ///  the leg's pinned gateway or peer is no longer the chain's.
    function resendValidation(uint256 validationId, bytes32 chainKey, bytes calldata to, bytes calldata spender)
        external
    {
        TransferValidationLib.resend(
            validationId,
            chainKey,
            to,
            spender,
            address(_boundToken()),
            _canCallSelector(msg.sender, this.resendValidation.selector)
        );
    }

    /* ----- Views ----- */

    /// @inheritdoc ITransferValidation
    function defaultValidityWindow() public view returns (uint64) {
        return _validationStorage().defaultValidityWindow;
    }

    /// @inheritdoc ITransferValidation
    function reconciliationWindowOf(bytes32 chainKey) public view returns (uint64) {
        return _validationStorage().reconciliationWindows[chainKey];
    }

    /// @inheritdoc ITransferValidation
    function isIssuancePaused(bytes32 chainKey) public view returns (bool) {
        return _validationStorage().issuancePaused[chainKey];
    }

    /// @inheritdoc ITransferValidation
    function lastValidationId() public view returns (uint256) {
        return _validationStorage().lastValidationId;
    }

    /// @inheritdoc ITransferValidation
    function validationOf(uint256 validationId) public view returns (Validation memory) {
        return _validationStorage().validations[validationId];
    }

    /// @inheritdoc ITransferValidation
    function statusOf(uint256 validationId) public view returns (ValidationStatus) {
        TransferValidationLib.ValidationStorage storage store = _validationStorage();
        require(TransferValidationLib.isRecorded(store, validationId), ErrorsLib.UnknownValidation(validationId));
        Validation storage validation = store.validations[validationId];
        // `Expired` is the one status never stored: it is `Pending` once the clock has passed `releaseAt`, or
        // `AwaitingApproval` once its deadline for an answer passed. Either way it can now be discarded. Every
        // other state is returned as it stands, including which leg a pair is still waiting for.
        bool pendingPastRelease =
            validation.status == ValidationStatus.Pending && block.timestamp > validation.releaseAt;
        bool unansweredPastDeadline =
            validation.status == ValidationStatus.AwaitingApproval && block.timestamp >= validation.expiry;
        if (pendingPastRelease || unansweredPastDeadline) return ValidationStatus.Expired;
        return validation.status;
    }

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

    /* ----- What the compliance provides ----- */

    /// @dev The token this compliance is bound to.
    function _boundToken() internal view virtual returns (IToken);

    /// @dev The AccessManager of this compliance.
    function _authority() internal view virtual returns (address);

    /// @dev Whether the AccessManager lets `caller` call `selector` on this contract now.
    function _canCallSelector(address caller, bytes4 selector) internal view virtual returns (bool);

    function _validationStorage() internal pure returns (TransferValidationLib.ValidationStorage storage) {
        return TransferValidationLib.layout();
    }

}
