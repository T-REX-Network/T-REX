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

import { AuthorityUtils } from "@openzeppelin/contracts/access/manager/AuthorityUtils.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { ITREXMessaging } from "../../interop/ITREXMessaging.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { MessageTypesLib } from "../../libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "../../libraries/WalletKeyLib.sol";
import { ITREXRegistry } from "../../registry/interface/ITREXRegistry.sol";
import { IToken } from "../../token/IToken.sol";
import { ComplianceLedgerLib } from "./ComplianceLedgerLib.sol";
import { ITransferValidation } from "./ITransferValidation.sol";
import { ModuleSetLib } from "./ModuleSetLib.sol";
import { TransferContextLib } from "./TransferContextLib.sol";
import { IApprovalModule } from "./modules/IApprovalModule.sol";
import { IModule } from "./modules/IModule.sol";

/**
 * @title TransferValidationLib
 * @dev The layout of the compliance's validation record, and the issuance half of a validation's life,
 * deployed once and linked: the questions a request must answer, then the id derived from the sender and the
 * salt, the record, the reservation, the announcement and the legs the satellites will execute against; the
 * answer of an approval; a resend.
 *
 * That is storage writes and ABI encoding the compliance would otherwise carry, and it is what kept it over
 * EIP-170. The compliance reaches it by DELEGATECALL, so the storage is its own namespaces at the slots they
 * always had, the token and the modules see the compliance as their caller, and every event is the
 * compliance's. What happens once a satellite executed, or never did, is {TransferSettlementLib}.
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
        /// The recipient's and the spender's envelopes, for a validation `AwaitingApproval` alone: what it is
        /// issued with once approved. Deleted by the answer.
        mapping(bytes32 validationId => AwaitedTerms terms) awaitedTerms;
        /// Legs reported for an id with no issued body, per origin chain, see {ITransferValidation-ParkedLeg}.
        /// Written by the settlement path, consumed by {TransferSettlementLib-settleParkedLeg}.
        mapping(bytes32 validationId => mapping(bytes32 chainKey => ITransferValidation.ParkedLeg leg)) parkedLegs;
        /// Every settlement delivery consumed, by `keccak256(abi.encode(chainKey, notification))`, whatever its
        /// outcome was: applied, parked, refused or a replay. Written once and kept, so the same leg delivered
        /// again from the same chain, under another receive id, is told apart from a new one, as the token keeps
        /// `settledProofs` for burn proofs.
        mapping(bytes32 deliveryKey => bool consumed) reportedLegs;
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

    /// @dev Issues a validation, see {ITransferValidation-requestTransferValidation}. Five questions, in order:
    ///  where is this going, may the caller ask for it, by when must it happen, how much may actually move, and
    ///  may the named spender execute it. Only then is anything written.
    /// @param salt the requester's nonce, see {ITransferValidation-requestTransferValidation}
    /// @param token the token the compliance is bound to
    /// @param authority the compliance's AccessManager
    /// @return validationId `keccak256(abi.encode(canonicalKey(from), salt))`
    function request(
        bytes calldata from,
        bytes calldata to,
        uint256 requestedMin,
        uint256 requestedMax,
        bytes calldata spender,
        bytes32 salt,
        address token,
        address authority
    ) external returns (bytes32 validationId) {
        require(requestedMin <= requestedMax, ErrorsLib.InvalidRequestedRange(requestedMin, requestedMax));

        Draft memory draft;
        draft.amountMin = requestedMin;
        draft.amountMax = requestedMax;
        _resolveRoute(draft, from, to, spender);
        _requireCallerOwnsTheWallet(draft, from, token, authority);
        (draft.expiry, draft.reconciliationWindow) =
            _expiryAndWindow(token, draft.fromChainKey, draft.toChainKey, draft.twoLegs);
        _narrowAmountRange(draft, from, to, spender, token);
        _requireSpenderAllowed(draft, to, spender);

        // Issued and sent at once, or kept awaiting approval while an `APPROVAL` module is bound.
        validationId = _issue(from, to, spender, salt, draft, token);
    }

    /// @dev Where the movement goes: both envelopes parse, the sender sits on a satellite, and the legs are
    ///  two when the wallets are on two different satellite chains. The spender is parsed here and judged in
    ///  {_requireSpenderAllowed}, once the range is known.
    function _resolveRoute(Draft memory draft, bytes calldata from, bytes calldata to, bytes calldata spender)
        private
        view
    {
        (bool fromNative,) = WalletKeyLib.isReferenceChain(from);
        require(!fromNative, ErrorsLib.SenderNotOnSatellite(from));
        (bool toNative,) = WalletKeyLib.isReferenceChain(to);
        draft.fromChainKey = _chainKeyOf(from);
        draft.toChainKey = _chainKeyOf(to);
        draft.twoLegs = !toNative && draft.fromChainKey != draft.toChainKey;
        if (spender.length != 0) WalletKeyLib.parse(spender);
    }

    /// @dev Who may ask: the identity the sending wallet is linked to, or an address the AccessManager
    ///  authorised for this selector. A satellite wallet never matches its own bytes, so a wallet can never
    ///  request a validation for itself; its identity does that.
    function _requireCallerOwnsTheWallet(Draft memory draft, bytes calldata from, address token, address authority)
        private
        view
    {
        draft.fromIdentity = address(_registryOf(token).resolveIdentity(from));
        require(draft.fromIdentity != address(0), ErrorsLib.UnverifiedWallet(from));
        bool callerIsTheWalletsIdentity = msg.sender == draft.fromIdentity;
        require(
            callerIsTheWalletsIdentity || _mayRequestForAnyWallet(authority),
            ErrorsLib.NotAuthorizedForWallet(msg.sender, from)
        );
    }

    /// @dev Whether the AccessManager lets the caller request a validation for any wallet, now. Asked only when
    ///  the caller is not the wallet's identity, so an identity pays no call to the manager.
    function _mayRequestForAnyWallet(address authority) private view returns (bool) {
        (bool immediate,) = AuthorityUtils.canCallWithDelay(
            authority, msg.sender, address(this), ITransferValidation.requestTransferValidation.selector
        );
        return immediate;
    }

    /// @dev How much may move. The range only ever narrows: first to what the sending wallet still has free,
    ///  then to the smallest amount the rules allow.
    function _narrowAmountRange(
        Draft memory draft,
        bytes calldata from,
        bytes calldata to,
        bytes calldata spender,
        address token
    ) private view {
        ITREXRegistry registry = _registryOf(token);
        require(registry.isWalletVerified(to), ErrorsLib.UnverifiedWallet(to));
        draft.toIdentity = address(registry.resolveIdentity(to));
        draft.fromKey = WalletKeyLib.canonicalKey(from);

        _capAtWhatTheWalletCanSend(draft, from, token);
        _capAtWhatTheRulesAllow(draft, to, spender);
        require(draft.amountMax != 0, ErrorsLib.ZeroValue());
    }

    /// @dev Caps the range at what the sending wallet can still send: its bridged balance less what earlier
    ///  validations may still draw from it and less what an open recall is taking back.
    function _capAtWhatTheWalletCanSend(Draft memory draft, bytes calldata from, address token) private view {
        uint256 free = IToken(token).availableOf(from);
        if (free < draft.amountMax) draft.amountMax = free;
        require(draft.amountMin <= draft.amountMax, ErrorsLib.EmptyValidationRange(draft.amountMin, draft.amountMax));
    }

    /// @dev Caps the range at the smallest amount the rules allow. Skipped when both wallets belong to one
    ///  identity, since relocating your own tokens changes no position and no distribution rule applies.
    function _capAtWhatTheRulesAllow(Draft memory draft, bytes calldata to, bytes calldata spender) private view {
        if (ComplianceLedgerLib.isRelocation(draft.fromIdentity, draft.toIdentity)) return;
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
        uint256 allowed = ModuleSetLib.callCheckTransfer(ctx);
        if (allowed < draft.amountMax) draft.amountMax = allowed;
        require(draft.amountMin <= draft.amountMax, ErrorsLib.EmptyValidationRange(draft.amountMin, draft.amountMax));
    }

    /// @dev Who may execute: every `SPENDER` module must accept the named spender, since no module runs on the
    ///  satellite and this is the only place it can be refused. A validation the sender executes itself names
    ///  no spender and asks nobody. Asked on a relocation too: who executes is not about distribution.
    function _requireSpenderAllowed(Draft memory draft, bytes calldata to, bytes calldata spender) private view {
        if (spender.length == 0) return;
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
        require(ModuleSetLib.spenderAllowed(ctx), ErrorsLib.ValidationSpenderRefused(spender));
    }

    /// @dev Turns a settled draft into a validation: derive its id from the sender and the salt, refuse an id
    ///  already taken, keep its terms and reserve the amount. With no `APPROVAL` module bound, issue it at once:
    ///  build the object the satellite will execute against, announce it and send one leg per satellite chain
    ///  involved. With one bound, keep it `AwaitingApproval` instead, sent nowhere until {answerApproval}.
    /// @param salt the requester's nonce, see {ITransferValidation-requestTransferValidation}
    /// @param token the token the compliance is bound to
    /// @return validationId `keccak256(abi.encode(draft.fromKey, salt))`
    function _issue(
        bytes calldata from,
        bytes calldata to,
        bytes calldata spender,
        bytes32 salt,
        Draft memory draft,
        address token
    ) private returns (bytes32 validationId) {
        validationId = keccak256(abi.encode(draft.fromKey, salt));
        require(!isRecorded(layout(), validationId), ErrorsLib.ValidationAlreadyRequested(validationId));
        _record(validationId, from, to, spender, draft, token);
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

    /// @dev The leg of an issued validation, rebuilt from its record and the two envelopes the caller supplies
    ///  again, for a resend. The rebuilt object must hash to what was issued, so a resend repeats the issuance
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
        requireInboundOpen(token, chainKey);
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
    function _expiryAndWindow(address token, bytes32 fromChainKey, bytes32 toChainKey, bool twoLegs)
        private
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
        requireInboundOpen(token, chainKey);
        window = store.reconciliationWindows[chainKey];
        require(window != 0, ErrorsLib.ReconciliationWindowNotSet(chainKey));
    }

    /// @dev Nothing goes toward a chain whose inbound the token has paused: its reports are held at the gateway,
    ///  so a leg sent now could only add to what cannot land, see {ITREXMessaging-setInboundPaused}.
    function requireInboundOpen(address token, bytes32 chainKey) internal view {
        require(!ITREXMessaging(token).isInboundPaused(chainKey), ErrorsLib.ChainInboundPaused(chainKey));
    }

    /// @dev Nothing is decided about a validation while a chain it still awaits has its inbound paused. The
    ///  reports held at that chain's gateway may already answer it: discarding or resolving on their absence
    ///  would release or return what they move, and they would then land on a validation that no longer expects
    ///  them. Which chains count follows the status: both while `Pending`, the one owing the missing leg once the
    ///  other landed.
    function requireAwaitedInboundOpen(address token, ITransferValidation.Validation storage validation) internal view {
        ITransferValidation.ValidationStatus status = validation.status;
        bool mintOwed = status == ITransferValidation.ValidationStatus.AwaitingMint
            || status == ITransferValidation.ValidationStatus.DiscardedAwaitingMint;
        bool burnOwed = status == ITransferValidation.ValidationStatus.AwaitingBurn
            || status == ITransferValidation.ValidationStatus.DiscardedAwaitingBurn;
        if (!mintOwed) requireInboundOpen(token, validation.fromChainKey);
        if (!burnOwed && validation.twoLegs) requireInboundOpen(token, validation.toChainKey);
    }

    /// @dev Pauses or resumes issuance toward a chain. Idempotent: the same state again changes nothing and
    ///  emits nothing.
    function setIssuancePaused(bytes32 chainKey, bool paused) internal {
        ValidationStorage storage store = layout();
        if (store.issuancePaused[chainKey] == paused) return;
        store.issuancePaused[chainKey] = paused;
        if (paused) emit EventsLib.ValidationIssuancePaused(chainKey);
        else emit EventsLib.ValidationIssuanceUnpaused(chainKey);
    }

    /// @dev Whether the id was taken: issued, or recorded awaiting approval. Every record names the identity the
    ///  sender resolved to, which is never zero, so that field says whether the slot was written.
    function isRecorded(ValidationStorage storage store, bytes32 validationId) internal view returns (bool) {
        return store.validations[validationId].fromIdentity != address(0);
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
    function discardUnanswered(bytes32 validationId, address token) internal {
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
    function _record(
        bytes32 validationId,
        bytes calldata from,
        bytes calldata to,
        bytes calldata spender,
        Draft memory draft,
        address token
    ) private {
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
        stored.spender = spender;
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
    ///  parked, and {TransferSettlementLib-settleParkedLeg} settles it instead. The token is the wire's only
    ///  author: it pins the route per leg and refuses a closed chain. As the compliance's DELEGATECALL target,
    ///  this library reaches the token with the compliance as the caller.
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

    /// @dev Keeps a recorded validation waiting for the approval module, with the two envelopes it is issued
    ///  with once approved, and tells the module. The validity window from now is the deadline for the answer.
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

    /// @dev Gives back `amount` of what a validation `AwaitingApproval` reserved: in the ledger's total, against
    ///  the identities unless it is a relocation, and against the sending wallet on the token. Mirrors what
    ///  `TransferSettlementLib._moveTo` releases when a status stops reserving, see `_stillReservesPending` and
    ///  `_stillReservesWallet` there: keep the two in step. It lives here because a narrowing gives back part
    ///  of the amount, which no status move does, and the library cannot call the contract's internals.
    function _release(ITransferValidation.Validation storage validation, uint256 amount, address token) private {
        ComplianceLedgerLib.Ledger storage ledger = ComplianceLedgerLib.layout();
        ledger.pendingTotal -= amount;
        if (!validation.relocation) {
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

    /// @dev The registry of the token the compliance is bound to.
    function _registryOf(address token) private view returns (ITREXRegistry) {
        return ITREXRegistry(address(IToken(token).identityRegistry()));
    }

    function _chainKeyOf(bytes calldata wallet) private pure returns (bytes32) {
        (bytes2 chainType, bytes memory chainReference,) = WalletKeyLib.parse(wallet);
        return MessageTypesLib.chainKey(chainType, chainReference);
    }

}
