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

import { ISettlementHandler } from "../../interop/ISettlementHandler.sol";
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
        /// Every requested validation, kept forever, under `keccak256(abi.encode(fromKey, salt))`.
        mapping(bytes32 validationId => ITransferValidation.Validation validation) validations;
        /// The two envelopes the record does not keep, for a validation `AwaitingApproval` alone: what it is
        /// issued with once approved. Deleted by the answer.
        mapping(bytes32 validationId => AwaitedTerms terms) awaitedTerms;
        /// Legs reported for an id with no issued body, per origin chain, see {ITransferValidation-ParkedLeg}.
        /// Written by the settlement path, consumed by the issuance of that id.
        mapping(bytes32 validationId => mapping(bytes32 chainKey => ITransferValidation.ParkedLeg leg)) parkedLegs;
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

    /// @dev Turns a settled draft into a validation: derive its id from the sender and the salt, refuse an id
    ///  already taken, keep its terms and reserve the amount. With no `APPROVAL` module bound, issue it at once:
    ///  build the object the satellite will execute against, announce it and send one leg per satellite chain
    ///  involved. With one bound, keep it `AwaitingApproval` instead, sent nowhere until {answerApproval}.
    /// @param salt the requester's nonce, see {ITransferValidation-requestTransferValidation}
    /// @param token the token the compliance is bound to
    /// @return validationId `keccak256(abi.encode(draft.fromKey, salt))`
    function issue(
        bytes calldata from,
        bytes calldata to,
        bytes calldata spender,
        bytes32 salt,
        Draft memory draft,
        address token
    ) external returns (bytes32 validationId) {
        validationId = keccak256(abi.encode(draft.fromKey, salt));
        require(!isRecorded(layout(), validationId), ErrorsLib.ValidationAlreadyRequested(validationId));
        _record(validationId, from, to, draft, token);
        layout().validations[validationId].salt = salt;

        address approvalModule = _approvalModule();
        if (approvalModule != address(0)) {
            _awaitApproval(validationId, from, to, spender, draft, approvalModule);
            return validationId;
        }

        bytes memory body = _issueRecorded(
            validationId,
            MessageTypesLib.ComplianceValidation({
                validationId: validationId,
                salt: salt,
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
        _dispatch(token, validationId, draft.fromChainKey, draft.toChainKey, draft.twoLegs, body);
    }

    /// @dev Answers a validation awaiting approval, see {ITransferValidation-answerApproval}. Issuing it runs
    ///  no rule again: every rule ran and the range was reserved at the request, so an approval only narrows,
    ///  checks the chains are still open and sends the legs. The legs go through the token, which as the
    ///  compliance's DELEGATECALL target sees the compliance as its caller.
    /// @param token the token the compliance is bound to
    function answerApproval(bytes32 validationId, uint256 approvedMax, address token) external {
        ValidationStorage storage store = layout();
        require(isRecorded(store, validationId), ErrorsLib.UnknownValidation(validationId));
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
                salt: validation.salt,
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

        _dispatch(token, validationId, validation.fromChainKey, validation.toChainKey, validation.twoLegs, body);
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
        bytes32 validationId,
        bytes32 chainKey,
        bytes calldata to,
        bytes calldata spender,
        address token,
        bool authorised
    ) external {
        ValidationStorage storage store = layout();
        require(isRecorded(store, validationId), ErrorsLib.UnknownValidation(validationId));
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
            salt: validation.salt,
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
        bytes32 validationId,
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
    function _requireAwaitedInboundOpen(address token, ITransferValidation.Validation storage validation) private view {
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

    /// @dev Whether the id was taken: issued, or recorded awaiting approval. Every record names the identity the
    ///  sender resolved to, which is never zero, so that field says whether the slot was written.
    function isRecorded(ValidationStorage storage store, bytes32 validationId) internal view returns (bool) {
        return store.validations[validationId].fromIdentity != address(0);
    }

    /* ----- Brakes and records the contract delegates ----- */

    /// @dev See {ITransferValidation-statusOf}. `Expired` is the one status never stored: it is `Pending` once
    ///  the clock has passed `releaseAt`, or `AwaitingApproval` once its deadline for an answer passed. Either way
    ///  it can now be discarded. Every other state is returned as it stands, including which leg a pair is still
    ///  waiting for.
    function statusOf(bytes32 validationId) external view returns (ITransferValidation.ValidationStatus status) {
        ValidationStorage storage store = layout();
        require(isRecorded(store, validationId), ErrorsLib.UnknownValidation(validationId));
        ITransferValidation.Validation storage validation = store.validations[validationId];
        status = validation.status;
        bool pendingPastRelease =
            status == ITransferValidation.ValidationStatus.Pending && block.timestamp > validation.releaseAt;
        bool unansweredPastDeadline =
            status == ITransferValidation.ValidationStatus.AwaitingApproval && block.timestamp >= validation.expiry;
        if (pendingPastRelease || unansweredPastDeadline) return ITransferValidation.ValidationStatus.Expired;
    }

    /// @dev Records a leg already accounted for, see {TransferValidation-_alreadyAccountedFor}: the caller pauses
    ///  the chain.
    function recordReplay(bytes32 validationId, bytes32 chainKey) external {
        emit EventsLib.ReplayedSettlement(validationId, chainKey);
    }

    /// @dev See {ITransferValidation-setIssuancePaused}. Idempotent: the same state again changes nothing and
    ///  emits nothing.
    function setIssuancePaused(bytes32 chainKey, bool paused) external {
        ValidationStorage storage store = layout();
        if (store.issuancePaused[chainKey] == paused) return;
        store.issuancePaused[chainKey] = paused;
        if (paused) emit EventsLib.ValidationIssuancePaused(chainKey);
        else emit EventsLib.ValidationIssuanceUnpaused(chainKey);
    }

    /// @dev A late leg always warns; the chain pauses only when the recorded state breaches a rule, since late
    ///  delivery is cheap to force and pausing on it would be a denial of service.
    function recordLateLeg(bytes32 validationId, bytes32 chainKey, bool breachesRule) external {
        emit EventsLib.LateReconciliation(validationId, chainKey);
        if (breachesRule) {
            ValidationStorage storage store = layout();
            if (store.issuancePaused[chainKey]) return;
            store.issuancePaused[chainKey] = true;
            emit EventsLib.ValidationIssuancePaused(chainKey);
        }
    }

    /// @dev The requirements of {ITransferValidation-resolveStuckValidation} and what the resolution returns or
    ///  stops, before the contract moves the validation to `Resolved`: the amount the burn leg put in transit goes
    ///  back to the wallet it left, or, when the mint leg is the one that landed, the chain owing the burn is
    ///  paused for issuance. The two status readings are the contract's, which keeps the lifecycle in one place.
    /// @param stuck whether exactly one leg of the pair arrived, read off the status by the contract
    /// @param burnArrived whether that leg was the burn leg, read off the status by the contract
    /// @param token the token the compliance is bound to
    /// @return returnedAmount what went back to the sender's wallet, zero when nothing was in transit
    function prepareResolution(bytes32 validationId, bool stuck, bool burnArrived, address token)
        external
        returns (uint256 returnedAmount)
    {
        ValidationStorage storage store = layout();
        require(isRecorded(store, validationId), ErrorsLib.UnknownValidation(validationId));
        ITransferValidation.Validation storage validation = store.validations[validationId];
        require(stuck, ErrorsLib.ValidationNotStuck(validationId, uint8(validation.status)));
        uint64 resolvableAt = validation.releaseAt + (validation.releaseAt - validation.expiry);
        require(block.timestamp > resolvableAt, ErrorsLib.ValidationNotYetResolvable(validationId, resolvableAt));
        _requireAwaitedInboundOpen(token, validation);

        if (burnArrived) {
            returnedAmount = validation.executedAmount;
            IToken(token).returnHeldInTransit(validation.legWallet, validationId);
        } else {
            bytes32 chainKey = validation.fromChainKey;
            if (!store.issuancePaused[chainKey]) {
                store.issuancePaused[chainKey] = true;
                emit EventsLib.ValidationIssuancePaused(chainKey);
            }
        }
    }

    /* ----- Judging a settlement leg ----- */

    /// @dev Announces an attributed settlement the token handed over, see {ISettlementHandler-handleSettlement}.
    function announce(bytes32 originChainKey, MessageTypesLib.SettlementNotification calldata notification) external {
        emit EventsLib.SettlementNotified(
            originChainKey, notification.validationId, notification.from, notification.to, notification.amount
        );
    }

    /// @dev Both chains must report the same amount: the first one to arrive recorded it, the second has to
    ///  repeat it. A mismatch means the two chains executed different movements under one id, which no ledger
    ///  can reconcile, so it is refused.
    function requireRepeatsFirstLeg(
        ITransferValidation.Validation storage validation,
        MessageTypesLib.SettlementNotification memory notification
    ) external view {
        require(
            notification.amount == validation.executedAmount,
            ErrorsLib.SettlementAmountMismatch(
                notification.validationId, validation.executedAmount, notification.amount
            )
        );
    }

    /// @dev A leg is one satellite chain's half of a movement, and the notification it sends back once it has
    ///  executed. A movement inside one satellite chain, or from a satellite to this one, is done by a single
    ///  chain: one leg, and the movement is complete when it arrives. A movement between two satellite chains is
    ///  done by two chains that cannot act atomically: the sending chain destroys the tokens on its side, the
    ///  receiving chain creates them on its side, and each reports its own half. This says which half a
    ///  notification is.
    enum Leg {
        /// The whole movement, reported by the only chain involved.
        Single,
        /// The sending chain destroyed its side. The tokens are now in transit, belonging to nobody.
        Burn,
        /// The receiving chain created its side.
        Mint
    }

    /// @dev What a leg judged against the issued terms comes to, see {judge}.
    enum Judgement {
        /// Inside the issued terms, from the chain recorded for its side: the contract applies it.
        Apply,
        /// Outside them: nothing is applied, the chain is paused, the validation stands.
        Refuse,
        /// Outside them, under another hash, from a chain the validation involves, while `Pending`: nothing is
        /// applied, the chain is paused, and the validation ends `Orphaned` with its reservation released.
        Orphan
    }

    /// @dev Judges a leg against the issued terms: the wallets it carries and the chain it comes from say which
    ///  leg it is, and its amount must sit inside the range. Inside the terms it is applied whatever hash it
    ///  names (`SettlementBodyDiverged` when not the issued one): the hash is evidence, never the gate.
    ///
    ///  Outside the terms nothing is applied and the chain is paused; the hash and the origin say which event
    ///  records it. A chain the validation does not involve could not have executed anything under it, whatever
    ///  hash it names: rejected. The issued hash from an involved chain: the Lite broke rule 5 or 6 on the body
    ///  this chain issued; rejected, and the validation stands, so the discard and the resolution still have
    ///  their say. Another hash from an involved chain: the Lite executed a body this chain never canonically
    ///  issued, which a reorg orphaned. While `Pending` the validation ends `Orphaned` and what it reserved comes
    ///  back, since the tokens moved under terms this chain never reserved for and the ledger cannot absorb an
    ///  amount outside them. In any other state it stands: a leg already landed and the keeper resolves the pair
    ///  after the second window, or the discard already gave the reservation back.
    ///
    ///  The hash is the Lite's word, which is why the orphaned reading is confined to the chains the validation
    ///  names. On one leg, the most a lying Lite gets is ending its own validation early, on its own chain, which
    ///  is paused for it. On a pair, the honest leg from the other chain then lands as a replay and pauses that
    ///  chain too: a hostile involved peer, answered as any hostile peer is, by distrusting its gateway.
    function judge(
        ITransferValidation.Validation storage validation,
        bytes32 originChainKey,
        MessageTypesLib.SettlementNotification memory notification
    ) external returns (Judgement judgement, Leg leg) {
        bool matches;
        (leg, matches) = _matchLeg(validation, originChainKey, notification);
        bool inRange = validation.amountMin <= notification.amount && notification.amount <= validation.amountMax;
        if (matches && inRange) {
            if (notification.hash != validation.hash) {
                emit EventsLib.SettlementBodyDiverged(notification.validationId, originChainKey, notification.hash);
            }
            return (Judgement.Apply, leg);
        }

        bool involved = originChainKey == validation.fromChainKey
            || (validation.twoLegs && originChainKey == validation.toChainKey);
        if (!involved || notification.hash == validation.hash) {
            emit EventsLib.SettlementRejected(
                notification.validationId, originChainKey, notification.amount, notification.hash
            );
            return (Judgement.Refuse, leg);
        }
        emit EventsLib.ValidationOrphaned(
            notification.validationId, originChainKey, notification.amount, notification.hash
        );
        bool pending = validation.status == ITransferValidation.ValidationStatus.Pending;
        return (pending ? Judgement.Orphan : Judgement.Refuse, leg);
    }

    /// @dev Keeps a leg reported for an id nothing was issued under, one per origin chain, so that once the
    ///  request is sent again with the same salt it can be settled, see {takeParkedLeg}. A second leg from the
    ///  same chain is a replay. Either way the caller pauses the chain: it executed what this chain never sent.
    function park(bytes32 originChainKey, MessageTypesLib.SettlementNotification memory notification) external {
        ITransferValidation.ParkedLeg storage parked = layout().parkedLegs[notification.validationId][originChainKey];
        if (parked.exists) {
            emit EventsLib.ReplayedSettlement(notification.validationId, originChainKey);
            return;
        }
        parked.from = notification.from;
        parked.to = notification.to;
        parked.amount = notification.amount;
        parked.hash = notification.hash;
        parked.exists = true;
        emit EventsLib.SettlementParked(
            notification.validationId, originChainKey, notification.amount, notification.hash
        );
    }

    /// @dev Takes the leg parked under `(validationId, chainKey)` out of storage and hands it back as the
    ///  notification it was, for the contract to judge and apply as a delivery, see
    ///  {ITransferValidation-settleParkedLeg} for the requirements. A revert further on undoes the take.
    /// @param token the token the compliance is bound to
    function takeParkedLeg(bytes32 validationId, bytes32 chainKey, address token)
        external
        returns (MessageTypesLib.SettlementNotification memory notification)
    {
        ValidationStorage storage store = layout();
        ITransferValidation.ParkedLeg memory parked = store.parkedLegs[validationId][chainKey];
        require(
            parked.exists && store.validations[validationId].hash != bytes32(0),
            ErrorsLib.ParkedLegNotSettleable(validationId, chainKey)
        );
        require(!IToken(token).paused(), ErrorsLib.TokenPaused());
        // A delivered leg from a paused chain waits at the gateway; a parked one from it waits here, for the same
        // investigation. The re-request is refused under the pause too, see {_requireInboundOpen}.
        _requireInboundOpen(token, chainKey);
        delete store.parkedLegs[validationId][chainKey];
        notification = MessageTypesLib.SettlementNotification({
            validationId: validationId, from: parked.from, to: parked.to, amount: parked.amount, hash: parked.hash
        });
    }

    /// @dev What follows the judgement of a parked leg: settled, it is announced; refused, its verdict reaches the
    ///  token as it would have at delivery, see {IToken-applyVerdict}.
    function finishParkedLeg(bytes32 validationId, bytes32 chainKey, ISettlementHandler.Verdict verdict, address token)
        external
    {
        if (verdict == ISettlementHandler.Verdict.None) emit EventsLib.ParkedLegSettled(validationId, chainKey);
        else IToken(token).applyVerdict(chainKey, verdict);
    }

    /// @dev A leg is matched by the wallets it carries and the chain it comes from. A one-leg validation expects
    ///  both wallets, the issued ones, from `from`'s chain. A two-leg validation expects the burn leg, `to` empty,
    ///  from `from`'s chain, and the mint leg, `from` empty, from `to`'s chain; a leg carrying both wallets is
    ///  neither. Whether it matched is returned, not required: the caller decides what a mismatch means.
    function _matchLeg(
        ITransferValidation.Validation storage validation,
        bytes32 originChainKey,
        MessageTypesLib.SettlementNotification memory notification
    ) private view returns (Leg leg, bool matches) {
        bool fromMatches = notification.from.length != 0 && keccak256(notification.from) == validation.fromKey;
        bool toMatches = notification.to.length != 0 && keccak256(notification.to) == validation.toKey;
        if (!validation.twoLegs) {
            return (Leg.Single, fromMatches && toMatches && originChainKey == validation.fromChainKey);
        }
        if (fromMatches && notification.to.length == 0 && originChainKey == validation.fromChainKey) {
            return (Leg.Burn, true);
        }
        if (toMatches && notification.from.length == 0 && originChainKey == validation.toChainKey) {
            return (Leg.Mint, true);
        }
        return (Leg.Single, false);
    }

    /// @dev See {ITransferValidation-discardExpiredValidations}. Each id must be stored `Pending` and past
    ///  `releaseAt`; one still awaiting a leg is refused whatever the clock says. One refused id reverts the whole
    ///  batch. The keeper may discard from `releaseAt`, anyone from the end of the second window: a discard turns
    ///  a leg that lands afterwards into a late reconciliation, which can pause its chain's issuance, so during
    ///  the first window the keeper alone judges that a leg is late rather than slow. A validation still
    ///  `AwaitingApproval` is discarded by anyone once its deadline passed, since nothing was sent for it, and the
    ///  envelopes kept for the answer are deleted. Nor is a validation discarded while a chain it awaits has its
    ///  inbound paused on the token: its leg may be waiting at that gateway, see {_requireAwaitedInboundOpen}.
    ///
    ///  What a discard releases is what `Pending` and `AwaitingApproval` reserve, the identities' pending amounts
    ///  unless it is a relocation and the sender wallet's room on the token, see {_release}, which mirrors
    ///  `TransferValidation._moveTo`.
    /// @param keeper whether the caller holds the role bound to the discard selector
    /// @param token the token the compliance is bound to
    function discardExpired(bytes32[] calldata validationIds, bool keeper, address token) external {
        ValidationStorage storage store = layout();
        for (uint256 i = 0; i < validationIds.length; i++) {
            bytes32 validationId = validationIds[i];
            require(isRecorded(store, validationId), ErrorsLib.UnknownValidation(validationId));
            ITransferValidation.Validation storage validation = store.validations[validationId];
            ITransferValidation.ValidationStatus status = validation.status;

            if (status == ITransferValidation.ValidationStatus.AwaitingApproval) {
                require(
                    block.timestamp >= validation.expiry,
                    ErrorsLib.ValidationNotReleasable(validationId, validation.expiry)
                );
                delete store.awaitedTerms[validationId];
            } else {
                require(
                    status == ITransferValidation.ValidationStatus.Pending,
                    ErrorsLib.ValidationNotDiscardable(validationId, uint8(status))
                );
                uint64 releaseAt = validation.releaseAt;
                require(block.timestamp > releaseAt, ErrorsLib.ValidationNotReleasable(validationId, releaseAt));
                if (!keeper) {
                    uint64 publicAt = releaseAt + (releaseAt - validation.expiry);
                    require(
                        block.timestamp > publicAt, ErrorsLib.ValidationNotPubliclyDiscardable(validationId, publicAt)
                    );
                }
                _requireAwaitedInboundOpen(token, validation);
            }

            _release(validation, validation.amountMax, token);
            validation.status = ITransferValidation.ValidationStatus.Discarded;
            emit EventsLib.ValidationDiscarded(validationId);
        }
    }

    /// @dev Keeps the validation forever and reserves its amount. Everything written here is the issuance half
    ///  of the lifecycle; the hash is written once the validation is issued, see {_issueRecorded}.
    function _record(bytes32 validationId, bytes calldata from, bytes calldata to, Draft memory draft, address token)
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
    function _issueRecorded(bytes32 validationId, MessageTypesLib.ComplianceValidation memory issued)
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
            issued.reconciliationWindow,
            issued.salt
        );

        body = abi.encode(issued);
    }

    /// @dev Sends one leg of an issued validation to each satellite chain involved, except a chain that already
    ///  reported a leg for this id while nothing was issued under it: that Lite executed it already, the leg is
    ///  parked, and the issuance settles it instead. The token is the wire's only author: it pins the route per
    ///  leg and refuses a closed chain. As the compliance's DELEGATECALL target, this library reaches the token
    ///  with the compliance as the caller.
    function _dispatch(
        address token,
        bytes32 validationId,
        bytes32 fromChainKey,
        bytes32 toChainKey,
        bool twoLegs,
        bytes memory body
    ) private {
        mapping(bytes32 chainKey => ITransferValidation.ParkedLeg) storage parked = layout().parkedLegs[validationId];
        if (!parked[fromChainKey].exists) IToken(token).dispatchComplianceValidation(fromChainKey, validationId, body);
        if (twoLegs && !parked[toChainKey].exists) {
            IToken(token).dispatchComplianceValidation(toChainKey, validationId, body);
        }
    }

    /// @dev Keeps a recorded validation waiting for the approval module, with the two envelopes the record does
    ///  not keep otherwise, and tells the module. The validity window from now is the deadline for the answer.
    function _awaitApproval(
        bytes32 validationId,
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

    /// @dev Gives back `amount` of what a validation `Pending` or `AwaitingApproval` reserved, against the
    ///  identities unless it is a relocation, and against the sending wallet on the token. Mirrors what
    ///  `TransferValidation._moveTo` releases when a status stops reserving, see `_stillReservesIdentities` and
    ///  `_stillReservesWallet` there: keep the two in step. It lives here because a narrowing gives back part
    ///  of the amount, which no status move does, and the library cannot call the contract's internals.
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
