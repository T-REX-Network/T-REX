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

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { ITREXMessaging } from "../../interop/ITREXMessaging.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { MessageTypesLib } from "../../libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "../../libraries/WalletKeyLib.sol";
import { IToken } from "../../token/IToken.sol";
import { ComplianceLedgerLib } from "./ComplianceLedgerLib.sol";
import { ITransferValidation } from "./ITransferValidation.sol";
import { ModuleSetLib } from "./ModuleSetLib.sol";
import { TransferContextLib } from "./TransferContextLib.sol";
import { IApprovalModule } from "./modules/IApprovalModule.sol";
import { IModule } from "./modules/IModule.sol";

/**
 * @title TransferValidationLib
 * @dev The layout of the compliance's validation record, and the last step of an issuance, deployed once
 * and linked: once every question about a requested validation is answered, this takes the next id, keeps
 * the validation, reserves its amount, announces it and encodes what the satellites will execute against.
 *
 * That step is storage writes and ABI encoding the compliance would otherwise carry, and it is what kept
 * it over EIP-170. The compliance reaches it by DELEGATECALL, so the storage is its own namespaces at the
 * slots they always had, the token sees the compliance as its caller, and the event is the compliance's.
 * Deciding whether a validation may be issued, and sending its legs, stay in the compliance.
 */
library TransferValidationLib {

    using EnumerableSet for EnumerableSet.AddressSet;

    /// @custom:storage-location erc7201:erc3643.storage.TransferValidation
    struct ValidationStorage {
        /// Added to the issuance timestamp to compute `expiry`. Zero blocks issuance.
        uint64 defaultValidityWindow;
        /// Per-chain worst-case reconciliation latency. Zero blocks issuance toward that chain.
        mapping(bytes32 chainKey => uint64 window) reconciliationWindows;
        /// Per-chain issuance pause, set by the manager or a breaching late reconciliation, lifted by the manager
        /// only.
        mapping(bytes32 chainKey => bool paused) issuancePaused;
        /// The last id issued. Ids start at 1.
        uint256 lastValidationId;
        /// Every issued validation, kept forever.
        mapping(uint256 validationId => ITransferValidation.Validation validation) validations;
        /// The two envelopes the record does not keep, for a validation `AwaitingApproval` alone: what it is
        /// issued with once approved. Deleted by the answer.
        mapping(uint256 validationId => AwaitedTerms terms) awaitedTerms;
    }

    /// @dev The recipient's and the spender's envelopes of a validation awaiting approval.
    struct AwaitedTerms {
        bytes to;
        bytes spender;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.TransferValidation")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant VALIDATION_STORAGE_LOCATION =
        0x518dcda4927033bd42da8dd6047b92b4a950cebbc5bdd8461a5e9bb9c0545400;

    /// @dev What issuance works out before the first write, in memory so the flow stays one function.
    struct Draft {
        bytes32 fromChainKey;
        bytes32 toChainKey;
        bool twoLegs;
        address fromIdentity;
        address toIdentity;
        bytes32 fromKey;
        uint256 amountMin;
        uint256 amountMax;
        uint64 expiry;
        uint64 reconciliationWindow;
    }

    /// @dev Turns a settled draft into a validation: take the next id, keep its terms and reserve the amount.
    ///  With no `APPROVAL` module bound, issue it at once: build the object the satellite will execute against
    ///  and announce it. With one bound, keep it `AwaitingApproval` instead, until {answerApproval}.
    /// @param token the token the compliance is bound to
    /// @return validationId the id taken
    /// @return body the encoded validation, for the compliance to send, one leg per satellite chain involved;
    ///  empty while it awaits approval, since nothing is sent yet
    function issue(bytes calldata from, bytes calldata to, bytes calldata spender, Draft memory draft, address token)
        external
        returns (uint256 validationId, bytes memory body)
    {
        validationId = ++layout().lastValidationId;
        _record(validationId, from, to, draft, token);

        address approvalModule = _approvalModule();
        if (approvalModule != address(0)) {
            _awaitApproval(validationId, from, to, spender, draft, approvalModule);
            return (validationId, "");
        }

        body = _issueRecorded(
            validationId,
            MessageTypesLib.ComplianceValidation({
                validationId: validationId,
                from: from,
                to: to,
                spender: spender,
                amountMin: draft.amountMin,
                amountMax: draft.amountMax,
                expiry: draft.expiry,
                reconciliationWindow: draft.reconciliationWindow,
                token: token
            })
        );
    }

    /// @dev Answers a validation awaiting approval, see {ITransferValidation-answerApproval}. Issuing it runs
    ///  no rule again: every rule ran and the range was reserved at the request, so an approval only narrows,
    ///  checks the chains are still open and sends the legs. The legs go through the token, which as the
    ///  compliance's DELEGATECALL target sees the compliance as its caller.
    /// @param token the token the compliance is bound to
    function answerApproval(uint256 validationId, uint256 approvedMax, address token) external {
        ValidationStorage storage store = layout();
        require(validationId != 0 && validationId <= store.lastValidationId, ErrorsLib.UnknownValidation(validationId));
        ITransferValidation.Validation storage validation = store.validations[validationId];
        require(
            validation.status == ITransferValidation.ValidationStatus.AwaitingApproval,
            ErrorsLib.ValidationNotAwaitingApproval(validationId, uint8(validation.status))
        );
        require(msg.sender == _approvalModule(), ErrorsLib.NotTheApprovalModule(msg.sender));
        require(block.timestamp < validation.expiry, ErrorsLib.ValidationExpired(validationId, validation.expiry));

        if (approvedMax == 0 || approvedMax < validation.amountMin) {
            _release(validation, validation.amountMax, token);
            validation.status = ITransferValidation.ValidationStatus.Discarded;
            delete store.awaitedTerms[validationId];
            emit EventsLib.ValidationApprovalRefused(validationId);
            return;
        }

        if (approvedMax < validation.amountMax) {
            _release(validation, validation.amountMax - approvedMax, token);
            validation.amountMax = approvedMax;
        }
        // The deadline stays the request's: the rules ran then, so the time spent waiting comes out of the
        // satellite's time to execute rather than adding to how old the rules may be when it does. The chains
        // are checked again, since one may have been paused while the request waited.
        _openChainWindow(store, token, validation.fromChainKey);
        if (validation.twoLegs) _openChainWindow(store, token, validation.toChainKey);
        validation.status = ITransferValidation.ValidationStatus.Pending;

        bytes memory body = _issueRecorded(
            validationId,
            MessageTypesLib.ComplianceValidation({
                validationId: validationId,
                from: validation.fromWallet,
                to: store.awaitedTerms[validationId].to,
                spender: store.awaitedTerms[validationId].spender,
                amountMin: validation.amountMin,
                amountMax: validation.amountMax,
                expiry: validation.expiry,
                reconciliationWindow: validation.releaseAt - validation.expiry,
                token: token
            })
        );
        delete store.awaitedTerms[validationId];

        IToken(token).dispatchComplianceValidation(validation.fromChainKey, validationId, body);
        if (validation.twoLegs) IToken(token).dispatchComplianceValidation(validation.toChainKey, validationId, body);
    }

    /// @dev The leg of an issued validation, rebuilt from its record and the two envelopes the record does not
    ///  keep, for a resend. The rebuilt object must hash to what was issued, so a resend repeats the issuance
    ///  byte for byte and can neither widen nor retarget it. Announces the resend and sends it through the token,
    ///  which as the compliance's DELEGATECALL target sees the compliance as its caller, as {_record} relies on.
    ///
    ///  While `Pending` either leg may go again, before `expiry`, since past it no satellite may execute. Once the
    ///  burn landed and the mint is owed, the recipient's leg alone may go again, before `releaseAt`: the receiving
    ///  Lite mints on the sending Lite's burn message and checks it against this very leg, so without it the pair
    ///  stays stuck; but a leg sent later could reach the Lite after the second window closed and the pair was
    ///  resolved, when the burned amount is already back with the sender on the ledger, and mint on the receiving
    ///  chain an amount the ledger then attributes to the wrong wallet. `releaseAt` leaves one reconciliation
    ///  window between the last resend and the resolution, as between the last execution and the discard. A burn
    ///  that lands after a discard is past `releaseAt` by definition, so a discarded pair is never resendable.
    ///  Issuance paused toward `chainKey` refuses a resend as it refuses an issuance: the pause exists to send
    ///  nothing more toward that chain.
    ///
    ///  The sender's identity may resend either leg, the recipient's the leg toward the recipient's chain: both
    ///  wait on it, and a resend can change nothing. Nothing is written, so nothing counts or spaces resends: the
    ///  token forwards no value to the gateway, a resend costs its caller the gas and whatever the gateway charges,
    ///  and the Lite ignores a leg it already holds.
    /// @param token the token the compliance is bound to
    /// @param authorised whether the AccessManager lets the caller resend any wallet's validation
    function resend(
        uint256 validationId,
        bytes32 chainKey,
        bytes calldata to,
        bytes calldata spender,
        address token,
        bool authorised
    ) external {
        ValidationStorage storage store = layout();
        require(validationId != 0 && validationId <= store.lastValidationId, ErrorsLib.UnknownValidation(validationId));
        ITransferValidation.Validation storage validation = store.validations[validationId];
        _requireResendable(validation, validationId, chainKey);
        require(!store.issuancePaused[chainKey], ErrorsLib.ValidationIssuancePaused(chainKey));
        _requireInboundOpen(token, chainKey);
        require(
            msg.sender == validation.fromIdentity
                || (chainKey == validation.toChainKey && msg.sender == validation.toIdentity) || authorised,
            ErrorsLib.NotAuthorizedForWallet(msg.sender, validation.fromWallet)
        );

        MessageTypesLib.ComplianceValidation memory rebuilt = MessageTypesLib.ComplianceValidation({
            validationId: validationId,
            from: validation.fromWallet,
            to: to,
            spender: spender,
            amountMin: validation.amountMin,
            amountMax: validation.amountMax,
            expiry: validation.expiry,
            reconciliationWindow: validation.releaseAt - validation.expiry,
            token: token
        });
        require(
            MessageTypesLib.hashValidation(rebuilt) == validation.hash, ErrorsLib.ValidationBodyMismatch(validationId)
        );

        emit EventsLib.ValidationResent(validationId, chainKey);

        IToken(token).dispatchComplianceValidation(chainKey, validationId, abi.encode(rebuilt));
    }

    /// @dev Whether the leg toward `chainKey` may go again: see {resend}.
    function _requireResendable(
        ITransferValidation.Validation storage validation,
        uint256 validationId,
        bytes32 chainKey
    ) private view {
        require(
            chainKey == validation.fromChainKey || (validation.twoLegs && chainKey == validation.toChainKey),
            ErrorsLib.ChainNotPartOfValidation(validationId, chainKey)
        );
        ITransferValidation.ValidationStatus status = validation.status;
        bool pending = status == ITransferValidation.ValidationStatus.Pending;
        bool mintOwed = status == ITransferValidation.ValidationStatus.AwaitingMint;
        require(
            pending || (mintOwed && chainKey == validation.toChainKey),
            ErrorsLib.ValidationNotResendable(validationId, uint8(status))
        );
        uint64 deadline = pending ? validation.expiry : validation.releaseAt;
        require(block.timestamp < deadline, ErrorsLib.ValidationExpired(validationId, deadline));
    }

    /// @dev By when: the satellite's deadline from the validity window, and the reservation's from the larger
    ///  reconciliation window of the chains involved. Every chain involved must be open and configured.
    function expiryAndWindow(address token, bytes32 fromChainKey, bytes32 toChainKey, bool twoLegs)
        external
        view
        returns (uint64 expiry, uint64 window)
    {
        ValidationStorage storage store = layout();
        require(store.defaultValidityWindow != 0, ErrorsLib.ValidityWindowNotSet());
        window = _openChainWindow(store, token, fromChainKey);
        if (twoLegs) {
            uint64 toWindow = _openChainWindow(store, token, toChainKey);
            if (toWindow > window) window = toWindow;
        }
        expiry = uint64(block.timestamp) + store.defaultValidityWindow;
    }

    /// @dev The reconciliation window of a chain a leg may go to: issuance toward it not paused by the compliance,
    ///  its inbound not paused by the token, and a window configured.
    function _openChainWindow(ValidationStorage storage store, address token, bytes32 chainKey)
        private
        view
        returns (uint64 window)
    {
        require(!store.issuancePaused[chainKey], ErrorsLib.ValidationIssuancePaused(chainKey));
        _requireInboundOpen(token, chainKey);
        window = store.reconciliationWindows[chainKey];
        require(window != 0, ErrorsLib.ReconciliationWindowNotSet(chainKey));
    }

    /// @dev Nothing goes toward a chain whose inbound the token has paused: its reports are held at the gateway,
    ///  so a leg sent now could only add to what cannot land, see {ITREXMessaging-setInboundPaused}.
    function _requireInboundOpen(address token, bytes32 chainKey) private view {
        require(!ITREXMessaging(token).isInboundPaused(chainKey), ErrorsLib.ChainInboundPaused(chainKey));
    }

    /// @dev Nothing is decided about a validation while a chain it still awaits has its inbound paused. The
    ///  reports held at that chain's gateway may already answer it: discarding or resolving on their absence
    ///  would release or return what they move, and they would then land on a validation that no longer expects
    ///  them. Which chains count follows the status: both while `Pending`, the one owing the missing leg once the
    ///  other landed.
    function requireAwaitedInboundOpen(address token, ITransferValidation.Validation storage validation) external view {
        ITransferValidation.ValidationStatus status = validation.status;
        bool mintOwed = status == ITransferValidation.ValidationStatus.AwaitingMint
            || status == ITransferValidation.ValidationStatus.DiscardedAwaitingMint;
        bool burnOwed = status == ITransferValidation.ValidationStatus.AwaitingBurn
            || status == ITransferValidation.ValidationStatus.DiscardedAwaitingBurn;
        if (!mintOwed) _requireInboundOpen(token, validation.fromChainKey);
        if (!burnOwed && validation.twoLegs) _requireInboundOpen(token, validation.toChainKey);
    }

    function layout() internal pure returns (ValidationStorage storage $) {
        assembly ("memory-safe") {
            $.slot := VALIDATION_STORAGE_LOCATION
        }
    }

    /// @dev Discards a validation still `AwaitingApproval` once its deadline passed, for anyone, see
    ///  {ITransferValidation-discardExpiredValidations}: nothing was sent for it, so no leg can be in flight.
    ///  The reservation comes back and the envelopes kept for the answer are deleted.
    /// @param token the token the compliance is bound to
    function discardUnanswered(uint256 validationId, address token) external {
        ValidationStorage storage store = layout();
        ITransferValidation.Validation storage validation = store.validations[validationId];
        require(
            block.timestamp >= validation.expiry, ErrorsLib.ValidationNotReleasable(validationId, validation.expiry)
        );
        _release(validation, validation.amountMax, token);
        validation.status = ITransferValidation.ValidationStatus.Discarded;
        delete store.awaitedTerms[validationId];
        emit EventsLib.ValidationDiscarded(validationId);
    }

    /// @dev Keeps the validation forever and reserves its amount. Everything written here is the issuance half
    ///  of the lifecycle; the hash is written once the validation is issued, see {_issueRecorded}.
    function _record(uint256 validationId, bytes calldata from, bytes calldata to, Draft memory draft, address token)
        private
    {
        ITransferValidation.Validation storage stored = layout().validations[validationId];
        stored.amountMin = draft.amountMin;
        stored.amountMax = draft.amountMax;
        stored.expiry = draft.expiry;
        stored.releaseAt = draft.expiry + draft.reconciliationWindow;
        stored.fromChainKey = draft.fromChainKey;
        stored.toChainKey = draft.toChainKey;
        stored.fromKey = draft.fromKey;
        stored.fromWallet = from;
        stored.toKey = WalletKeyLib.canonicalKey(to);
        stored.twoLegs = draft.twoLegs;
        stored.fromIdentity = draft.fromIdentity;
        stored.toIdentity = draft.toIdentity;
        // `reservePending` returns whether it reserved against the identities; it does not on a relocation.
        stored.relocation = !ComplianceLedgerLib.reservePending(draft.fromIdentity, draft.toIdentity, draft.amountMax);
        IToken(token).reserveForValidation(from, draft.amountMax);
    }

    /// @dev Writes the hash of what the satellite will execute against, announces it, and encodes it.
    function _issueRecorded(uint256 validationId, MessageTypesLib.ComplianceValidation memory issued)
        private
        returns (bytes memory body)
    {
        layout().validations[validationId].hash = MessageTypesLib.hashValidation(issued);

        emit EventsLib.TransferValidationIssued(
            validationId,
            issued.from,
            issued.to,
            issued.spender,
            issued.amountMin,
            issued.amountMax,
            issued.expiry,
            issued.reconciliationWindow
        );

        body = abi.encode(issued);
    }

    /// @dev Keeps a recorded validation waiting for the approval module, with the two envelopes the record does
    ///  not keep otherwise, and tells the module. The validity window from now is the deadline for the answer.
    function _awaitApproval(
        uint256 validationId,
        bytes calldata from,
        bytes calldata to,
        bytes calldata spender,
        Draft memory draft,
        address approvalModule
    ) private {
        ITransferValidation.Validation storage stored = layout().validations[validationId];
        stored.status = ITransferValidation.ValidationStatus.AwaitingApproval;
        layout().awaitedTerms[validationId] = AwaitedTerms({ to: to, spender: spender });

        emit EventsLib.TransferValidationAwaitingApproval(
            validationId, from, to, spender, draft.amountMin, draft.amountMax, draft.expiry
        );

        IModule.TransferContext memory ctx = TransferContextLib.issuance(
            address(this),
            draft.fromIdentity,
            draft.toIdentity,
            draft.fromKey,
            WalletKeyLib.walletId(to),
            draft.amountMin,
            draft.amountMax,
            spender
        );
        IApprovalModule(approvalModule).approvalRequested(validationId, ctx, draft.expiry);
    }

    /// @dev Gives back `amount` of what a validation reserved, against the identities unless it is a
    ///  relocation, and against the sending wallet on the token.
    function _release(ITransferValidation.Validation storage validation, uint256 amount, address token) private {
        if (!validation.relocation) {
            ComplianceLedgerLib.Ledger storage ledger = ComplianceLedgerLib.layout();
            ledger.pendingOut[validation.fromIdentity] -= amount;
            ledger.pendingIn[validation.toIdentity] -= amount;
        }
        IToken(token).releaseFromValidation(validation.fromWallet, amount);
    }

    /// @dev The bound `APPROVAL` module, or zero when none is: the compliance binds one at most.
    function _approvalModule() private view returns (address) {
        EnumerableSet.AddressSet storage approvalModules = ModuleSetLib.layout().byType[IModule.ModuleType.APPROVAL];
        if (approvalModules.length() == 0) return address(0);
        return approvalModules.at(0);
    }

}
