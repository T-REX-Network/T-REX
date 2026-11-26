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
import { ITickets } from "./ITickets.sol";
import { ModuleSetLib } from "./ModuleSetLib.sol";
import { TransferContextLib } from "./TransferContextLib.sol";
import { IApprovalModule } from "./modules/IApprovalModule.sol";
import { IModule } from "./modules/IModule.sol";

/**
 * @title TicketLib
 * @dev The layout of the compliance's validation record, and the issuance half of a validation's life,
 * deployed once and linked: the questions a request must answer, then the id built from the whole request,
 * the record, the reservation, the announcement and the ticket the away token will execute against; the
 * answer of an approval; a resend; and the table of what each ticket state keeps reserved, {moveTo}.
 *
 * That is storage writes and ABI encoding the compliance would otherwise carry, and it is what kept it over
 * EIP-170. The compliance reaches it by DELEGATECALL, so the storage is its own namespaces at the slots they
 * always had, the token and the modules see the compliance as their caller, and every event is the
 * compliance's. What happens once a satellite executed, or never did, is {ReceiptLib}.
 */
library TicketLib {

    using EnumerableSet for EnumerableSet.AddressSet;

    /// @custom:storage-location erc7201:erc3643.storage.TransferValidation
    struct ValidationStorage {
        /// Added to the issuance timestamp to compute `validUntil`. Zero blocks issuance.
        uint64 defaultValidityWindow;
        /// Per-chain worst-case reconciliation latency. Zero blocks issuance toward that chain.
        mapping(bytes32 chainKey => uint64 window) waitingTimes;
        /// Per-chain issuance pause, set by the manager or a breaching late reconciliation, lifted by the manager
        /// only.
        mapping(bytes32 chainKey => bool paused) issuancePaused;
        /// Every requested validation, kept forever, under its id, see {ticketIdOf}.
        mapping(bytes32 ticketId => ITickets.Ticket validation) validations;
        /// The recipient's and the spender's envelopes, for a validation `WaitingForApproval` alone: what it is
        /// issued with once approved. Deleted by the answer.
        mapping(bytes32 ticketId => AwaitedTerms terms) awaitedTerms;
        /// Receipts for a ticket written and never sent, per away chain, see {ITickets-WaitingReceipt}.
        /// Written by the receipt path, consumed by {ReceiptLib-applyWaitingReceipt}.
        mapping(bytes32 ticketId => mapping(bytes32 chainKey => ITickets.WaitingReceipt receipt)) waitingReceipts;
        /// The receipt home took in for each half, as `keccak256(abi.encode(chainKey, receipt))`, see
        /// {MessageTypesLib-halfKeyOf}. The same receipt again changes nothing; another one is a bad receipt.
        mapping(bytes32 halfKey => bytes32 receiptHash) receiptHashes;
        /// The caps on tickets toward each away chain.
        mapping(bytes32 chainKey => ITickets.TicketLimits limits) ticketLimits;
        /// The latest `validUntil` of a ticket sent toward each away chain: the per-ticket cap is lowered only
        /// once it has passed.
        mapping(bytes32 chainKey => uint64 validUntil) latestValidUntilSent;
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
        address fromIdentity;
        address toIdentity;
        bytes32 fromKey;
        bytes32 toKey;
        uint256 amountMin;
        uint256 amountMax;
        uint256 requestedMax;
        uint64 validUntil;
        uint64 waitingTime;
    }

    /// @dev Issues a validation, see {ITickets-askToMove}. Five questions, in order:
    ///  where is this going, may the caller ask for it, by when must it happen, how much may actually move, and
    ///  may the named spender execute it. Only then is anything written.
    /// @param salt the requester's nonce, see {ITickets-askToMove}
    /// @param token the token the compliance is bound to
    /// @param authority the compliance's AccessManager
    /// @return ticketId the id of the whole request, see {ticketIdOf}
    function request(
        bytes calldata from,
        bytes calldata to,
        uint256 requestedMin,
        uint256 requestedMax,
        bytes calldata spender,
        bytes32 salt,
        address token,
        address authority
    ) external returns (bytes32 ticketId) {
        require(requestedMin <= requestedMax, ErrorsLib.InvalidRequestedRange(requestedMin, requestedMax));

        Draft memory draft;
        draft.amountMin = requestedMin;
        draft.amountMax = requestedMax;
        draft.requestedMax = requestedMax;
        _resolveRoute(draft, from, to, spender);
        _requireCallerOwnsTheWallet(draft, from, token, authority);
        (draft.validUntil, draft.waitingTime) = _expiryAndWindow(token, draft.fromChainKey);
        _narrowAmountRange(draft, from, to, spender, token);
        _requireSpenderAllowed(draft, to, spender);

        // Issued and sent at once, or kept awaiting approval while an `APPROVAL` module is bound.
        ticketId = _issue(from, to, spender, salt, draft, token);
    }

    /// @dev Where the move goes: both envelopes parse, the sender sits on an away chain, and the receiver sits on
    ///  the same away chain or at home. A move between two away chains is done in two halves, home sending the
    ///  second one once the first is done, and is refused until home can send it. The spender is parsed here and
    ///  judged in {_requireSpenderAllowed}, once the range is known.
    function _resolveRoute(Draft memory draft, bytes calldata from, bytes calldata to, bytes calldata spender)
        private
        view
    {
        (bool fromNative,) = WalletKeyLib.isReferenceChain(from);
        require(!fromNative, ErrorsLib.SenderNotOnSatellite(from));
        (bool toNative,) = WalletKeyLib.isReferenceChain(to);
        draft.fromChainKey = _chainKeyOf(from);
        draft.toChainKey = _chainKeyOf(to);
        bool receiverOnTheSendersChain = draft.toChainKey == draft.fromChainKey;
        require(toNative || receiverOnTheSendersChain, ErrorsLib.ChainNotOpen(draft.toChainKey));
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
        (bool immediate,) =
            AuthorityUtils.canCallWithDelay(authority, msg.sender, address(this), ITickets.askToMove.selector);
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
        draft.toKey = WalletKeyLib.canonicalKey(to);

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

    /// @dev Turns a settled draft into a validation: build its id from the whole request, refuse an id
    ///  already taken, keep its terms and reserve the amount. With no `APPROVAL` module bound, issue it at once:
    ///  build the object the away token will execute against, announce it and send it to the sender's away
    ///  chain. With one bound, keep it `WaitingForApproval` instead, sent nowhere until {answerApproval}.
    /// @param salt the requester's nonce, see {ITickets-askToMove}
    /// @param token the token the compliance is bound to
    /// @return ticketId the id of the whole request, see {ticketIdOf}
    function _issue(
        bytes calldata from,
        bytes calldata to,
        bytes calldata spender,
        bytes32 salt,
        Draft memory draft,
        address token
    ) private returns (bytes32 ticketId) {
        ticketId = ticketIdOf(
            ITickets.TicketKind.MOVE,
            draft.fromKey,
            draft.toKey,
            keccak256(spender),
            draft.amountMin,
            draft.requestedMax,
            salt
        );
        require(!isRecorded(layout(), ticketId), ErrorsLib.TicketAlreadyWritten(ticketId));
        _record(ticketId, from, spender, draft, token);
        layout().validations[ticketId].salt = salt;

        address approvalModule = _approvalModule();
        if (approvalModule != address(0)) {
            _awaitApproval(ticketId, from, to, spender, draft, approvalModule);
            return ticketId;
        }

        bytes memory body = _issueRecorded(
            ticketId,
            MessageTypesLib.TicketMessage({
                ticketId: ticketId,
                salt: salt,
                from: from,
                to: to,
                spender: spender,
                amountMin: draft.amountMin,
                amountMax: draft.amountMax,
                requestedMax: draft.requestedMax,
                token: token,
                validUntil: draft.validUntil,
                askBlockHash: askBlockHashOf(draft.amountMax, draft.validUntil)
            })
        );
        _dispatch(token, ticketId, draft.fromChainKey, draft.validUntil, body);
    }

    /// @dev Answers a validation awaiting approval, see {ITickets-answerApproval}. Issuing it runs
    ///  no rule again: every rule ran and the range was reserved at the request, so an approval only narrows,
    ///  checks the sender's chain is still open and sends the ticket. It goes through the token, which as the
    ///  compliance's DELEGATECALL target sees the compliance as its caller.
    /// @param token the token the compliance is bound to
    function answerApproval(bytes32 ticketId, uint256 approvedMax, address token) external {
        ValidationStorage storage store = layout();
        require(isRecorded(store, ticketId), ErrorsLib.UnknownTicket(ticketId));
        ITickets.Ticket storage validation = store.validations[ticketId];
        require(
            validation.status == ITickets.TicketStatus.WaitingForApproval,
            ErrorsLib.ValidationNotAwaitingApproval(ticketId, uint8(validation.status))
        );
        require(msg.sender == _approvalModule(), ErrorsLib.NotTheApprovalModule(msg.sender));
        require(block.timestamp < validation.validUntil, ErrorsLib.ValidationExpired(ticketId, validation.validUntil));

        if (approvedMax == 0 || approvedMax < validation.amountMin) {
            moveTo(validation, ITickets.TicketStatus.Cancelled, token);
            delete store.awaitedTerms[ticketId];
            emit EventsLib.ValidationApprovalRefused(ticketId);
            return;
        }

        // The deadline stays the request's: the rules ran then, so the time spent waiting comes out of the
        // satellite's time to execute rather than adding to how old the rules may be when it does. The chain
        // is checked again, since it may have been paused while the request waited, and so is the token: all
        // of it before anything is written. Both rows hold the ask, so the narrowing alone gives something back.
        requireTokenRunning(token);
        _openChainWindow(store, token, validation.fromChainKey);

        if (approvedMax < validation.amountMax) {
            _release(validation, validation.amountMax - approvedMax, token);
            validation.amountMax = approvedMax;
        }
        validation.status = ITickets.TicketStatus.Open;

        bytes memory body = _issueRecorded(
            ticketId,
            MessageTypesLib.TicketMessage({
                ticketId: ticketId,
                salt: validation.salt,
                from: validation.fromWallet,
                to: store.awaitedTerms[ticketId].to,
                spender: store.awaitedTerms[ticketId].spender,
                amountMin: validation.amountMin,
                amountMax: validation.amountMax,
                requestedMax: validation.requestedMax,
                token: token,
                validUntil: validation.validUntil,
                askBlockHash: askBlockHashOf(validation.amountMax, validation.validUntil)
            })
        );
        delete store.awaitedTerms[ticketId];

        _dispatch(token, ticketId, validation.fromChainKey, validation.validUntil, body);
    }

    /// @dev The ticket, rebuilt from its record and the two envelopes the caller supplies again, for a resend. The
    ///  envelopes must be the ones the ticket was asked with and the ask block hash is the recorded one, so a resend
    ///  repeats the copy sent byte for byte and can neither widen nor retarget it. Announces the resend and sends it
    ///  through the token, which as the compliance's DELEGATECALL target sees the compliance as its caller.
    ///
    ///  Only while `Open` and before `validUntil`, since past it no away token may execute. Issuance paused toward
    ///  `chainKey` refuses a resend as it refuses an issuance, and so does the token's own pause, see
    ///  {requireTokenRunning}. The sender's identity may resend, and so may the receiver's when the receiver is on
    ///  the same away chain: both wait on it, and a resend can change nothing. Nothing is written, so nothing counts or spaces resends.
    /// @param token the token the compliance is bound to
    /// @param authorised whether the AccessManager lets the caller resend any wallet's validation
    function resend(
        bytes32 ticketId,
        bytes32 chainKey,
        bytes calldata to,
        bytes calldata spender,
        address token,
        bool authorised
    ) external {
        ValidationStorage storage store = layout();
        require(isRecorded(store, ticketId), ErrorsLib.UnknownTicket(ticketId));
        ITickets.Ticket storage validation = store.validations[ticketId];
        _requireResendable(validation, ticketId, chainKey);
        requireTokenRunning(token);
        require(!store.issuancePaused[chainKey], ErrorsLib.ValidationIssuancePaused(chainKey));
        requireInboundOpen(token, chainKey);
        _requireMayResend(validation, chainKey, authorised);

        require(WalletKeyLib.canonicalKey(to) == validation.toKey, ErrorsLib.ValidationBodyMismatch(ticketId));
        require(keccak256(spender) == keccak256(validation.spender), ErrorsLib.ValidationBodyMismatch(ticketId));

        MessageTypesLib.TicketMessage memory rebuilt = MessageTypesLib.TicketMessage({
            ticketId: ticketId,
            salt: validation.salt,
            from: validation.fromWallet,
            to: to,
            spender: spender,
            amountMin: validation.amountMin,
            amountMax: validation.amountMax,
            requestedMax: validation.requestedMax,
            token: token,
            validUntil: validation.validUntil,
            askBlockHash: validation.askBlockHash
        });

        emit EventsLib.TicketSent(ticketId, chainKey);

        IToken(token).dispatchComplianceValidation(chainKey, ticketId, abi.encode(rebuilt));
    }

    /// @dev Who may resend: the sender's identity, the receiver's when the receiver is on the ticket's away chain,
    ///  or an address the AccessManager authorised.
    function _requireMayResend(ITickets.Ticket storage validation, bytes32 chainKey, bool authorised) private view {
        bool callerIsTheSendersIdentity = msg.sender == validation.fromIdentity;
        bool receiverIsOnTheTicketsChain = chainKey == validation.toChainKey;
        bool callerIsTheReceiversIdentity = msg.sender == validation.toIdentity;
        bool callerIsAReceiverOnTheTicketsChain = receiverIsOnTheTicketsChain && callerIsTheReceiversIdentity;
        require(
            callerIsTheSendersIdentity || callerIsAReceiverOnTheTicketsChain || authorised,
            ErrorsLib.NotAuthorizedForWallet(msg.sender, validation.fromWallet)
        );
    }

    /// @dev Whether the ticket may go to `chainKey` again: see {resend}.
    function _requireResendable(ITickets.Ticket storage validation, bytes32 ticketId, bytes32 chainKey) private view {
        require(chainKey == validation.fromChainKey, ErrorsLib.ChainNotPartOfValidation(ticketId, chainKey));
        ITickets.TicketStatus status = validation.status;
        require(status == ITickets.TicketStatus.Open, ErrorsLib.ValidationNotResendable(ticketId, uint8(status)));
        require(block.timestamp < validation.validUntil, ErrorsLib.ValidationExpired(ticketId, validation.validUntil));
    }

    /// @dev By when: the away token's deadline from the validity window, and the reservation's from the waiting
    ///  time of the sender's away chain. The token must be running, and that chain open and configured: this is
    ///  where a request is refused with `TokenPaused`.
    function _expiryAndWindow(address token, bytes32 fromChainKey)
        private
        view
        returns (uint64 validUntil, uint64 window)
    {
        requireTokenRunning(token);
        ValidationStorage storage store = layout();
        require(store.defaultValidityWindow != 0, ErrorsLib.ValidityWindowNotSet());
        window = _openChainWindow(store, token, fromChainKey);
        validUntil = uint64(block.timestamp) + store.defaultValidityWindow;
    }

    /// @dev The waiting time of a chain a ticket may go to: issuance toward it not paused by the compliance,
    ///  its inbound not paused by the token, and a window configured.
    function _openChainWindow(ValidationStorage storage store, address token, bytes32 chainKey)
        private
        view
        returns (uint64 window)
    {
        require(!store.issuancePaused[chainKey], ErrorsLib.ValidationIssuancePaused(chainKey));
        requireInboundOpen(token, chainKey);
        window = store.waitingTimes[chainKey];
        require(window != 0, ErrorsLib.WaitingTimeNotSet(chainKey));
    }

    /// @dev Nothing goes out while the token is paused: an incident is under investigation, every settlement
    ///  reverts and waits at its gateway, so a validation sent now could only be executed on a satellite with its
    ///  report held, and its window could run out before the pause is lifted. Request, approval and resend alike.
    ///  For the same reason no ticket whose receipt may be in flight is cancelled under it, see
    ///  {requireAwaitedInboundOpen}.
    function requireTokenRunning(address token) internal view {
        require(!IToken(token).paused(), ErrorsLib.TokenPaused());
    }

    /// @dev Nothing goes toward a chain whose inbound the token has paused: its reports are held at the gateway,
    ///  so a ticket sent now could only add to what cannot land, see {ITREXMessaging-setInboundPaused}.
    function requireInboundOpen(address token, bytes32 chainKey) internal view {
        require(!ITREXMessaging(token).isInboundPaused(chainKey), ErrorsLib.AwayChainBlocked(chainKey));
    }

    /// @dev Nothing is decided about a ticket while the away chain that owes its receipt is blocked. The receipts
    ///  held at that chain's bridge may already answer it: cancelling on their absence would release what they
    ///  move. The token's own pause holds every chain's receipts the same way, so nothing is decided under it
    ///  either: a pause that outlasts `waitingEndsAt` would otherwise release a reservation whose receipt is
    ///  waiting, and the room it frees could be reserved again before that receipt lands.
    function requireAwaitedInboundOpen(address token, ITickets.Ticket storage validation) internal view {
        requireTokenRunning(token);
        requireInboundOpen(token, validation.fromChainKey);
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
    function isRecorded(ValidationStorage storage store, bytes32 ticketId) internal view returns (bool) {
        return store.validations[ticketId].fromIdentity != address(0);
    }

    /// @dev The id of a ticket: a hash of the whole request, never of the block it is mined in. The same request
    ///  gets the same id in any block, so a ticket sent before a reorg keeps its id when the ask is mined again.
    ///  `requestedMax` is the maximum as asked: home narrows `amountMax` from the state of the block, so it is left
    ///  out. `spenderKey` is `keccak256` of the spender's envelope, of empty bytes when there is none.
    function ticketIdOf(
        ITickets.TicketKind kind,
        bytes32 fromKey,
        bytes32 toKey,
        bytes32 spenderKey,
        uint256 amountMin,
        uint256 requestedMax,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(kind, fromKey, toKey, spenderKey, amountMin, requestedMax, salt));
    }

    /// @dev The ask block hash: names the copy of a ticket written in this block, the ask's own block, or the
    ///  answer's for a ticket that waited for approval. Two copies of one ask mined in two blocks share the id and
    ///  differ here; two sibling blocks share number and parent, so the terms are in it too.
    function askBlockHashOf(uint256 amountMax, uint64 validUntil) internal view returns (bytes32) {
        return keccak256(abi.encode(block.number, blockhash(block.number - 1), amountMax, validUntil));
    }

    function layout() internal pure returns (ValidationStorage storage $) {
        assembly ("memory-safe") {
            $.slot := VALIDATION_STORAGE_LOCATION
        }
    }

    /// @dev Discards a validation still `WaitingForApproval` once its deadline passed, for anyone, see
    ///  {ITickets-cancelTickets}: nothing was sent for it, so no receipt can be in flight.
    ///  The reservation comes back and the envelopes kept for the answer are deleted.
    /// @param token the token the compliance is bound to
    function discardUnanswered(bytes32 ticketId, address token) internal {
        ValidationStorage storage store = layout();
        ITickets.Ticket storage validation = store.validations[ticketId];
        require(block.timestamp >= validation.validUntil, ErrorsLib.CancelNotDue(ticketId, validation.validUntil));
        moveTo(validation, ITickets.TicketStatus.Cancelled, token);
        delete store.awaitedTerms[ticketId];
        emit EventsLib.TicketCancelled(ticketId);
    }

    /// @dev Keeps the validation forever and reserves its amount. Everything written here is the issuance half
    ///  of the lifecycle; the ask block hash is written once the validation is issued, see {_issueRecorded}.
    function _record(bytes32 ticketId, bytes calldata from, bytes calldata spender, Draft memory draft, address token)
        private
    {
        ITickets.Ticket storage stored = layout().validations[ticketId];
        stored.amountMin = draft.amountMin;
        stored.amountMax = draft.amountMax;
        stored.validUntil = draft.validUntil;
        stored.waitingEndsAt = draft.validUntil + draft.waitingTime;
        stored.fromChainKey = draft.fromChainKey;
        stored.toChainKey = draft.toChainKey;
        stored.fromKey = draft.fromKey;
        stored.fromWallet = from;
        stored.toKey = draft.toKey;
        stored.fromIdentity = draft.fromIdentity;
        stored.toIdentity = draft.toIdentity;
        stored.spender = spender;
        stored.requestedMax = draft.requestedMax;
        // Open unless an approval module is bound, see {_awaitApproval}.
        stored.status = ITickets.TicketStatus.Open;
        // `reservePending` returns whether it reserved against the identities; it does not on a relocation.
        stored.relocation = !ComplianceLedgerLib.reservePending(draft.fromIdentity, draft.toIdentity, draft.amountMax);
        IToken(token).reserveForTicket(from, draft.amountMax);
    }

    /// @dev Writes the ask block hash of the copy the away token will execute against, announces it, and encodes it.
    function _issueRecorded(bytes32 ticketId, MessageTypesLib.TicketMessage memory issued)
        private
        returns (bytes memory body)
    {
        layout().validations[ticketId].askBlockHash = issued.askBlockHash;

        emit EventsLib.TicketWritten(
            ticketId,
            issued.from,
            issued.to,
            issued.spender,
            issued.amountMin,
            issued.amountMax,
            issued.requestedMax,
            issued.validUntil,
            issued.askBlockHash,
            issued.salt
        );

        body = abi.encode(issued);
    }

    /// @dev Sends a written ticket to the sender's away chain, unless that chain already answered it while it was
    ///  not sent: that away token executed it already, its receipt waits here, and
    ///  {ReceiptLib-applyWaitingReceipt} applies it instead. The token is the wire's only author: it pins the
    ///  half and refuses a closed chain. As the compliance's DELEGATECALL target, this library reaches the token
    ///  with the compliance as the caller. The latest valid until sent toward the chain is kept for the cap
    ///  setter, see {ITickets-setTicketLimits}.
    function _dispatch(address token, bytes32 ticketId, bytes32 fromChainKey, uint64 validUntil, bytes memory body)
        private
    {
        ValidationStorage storage store = layout();
        if (validUntil > store.latestValidUntilSent[fromChainKey]) {
            store.latestValidUntilSent[fromChainKey] = validUntil;
        }
        if (store.waitingReceipts[ticketId][fromChainKey].exists) return;
        IToken(token).dispatchComplianceValidation(fromChainKey, ticketId, body);
    }

    /// @dev Keeps a recorded validation waiting for the approval module, with the two envelopes it is issued
    ///  with once approved, and tells the module. The validity window from now is the deadline for the answer.
    function _awaitApproval(
        bytes32 ticketId,
        bytes calldata from,
        bytes calldata to,
        bytes calldata spender,
        Draft memory draft,
        address approvalModule
    ) private {
        ITickets.Ticket storage stored = layout().validations[ticketId];
        stored.status = ITickets.TicketStatus.WaitingForApproval;
        layout().awaitedTerms[ticketId] = AwaitedTerms({ to: to, spender: spender });

        emit EventsLib.TicketWaitingForApproval(
            ticketId, from, to, spender, draft.amountMin, draft.amountMax, draft.validUntil
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
        IApprovalModule(approvalModule).approvalRequested(ticketId, ctx, draft.validUntil);
    }

    /// @dev Moves a ticket to `next` and releases what its old row of the table holds and the new row does not.
    ///  The table, one row per state:
    ///  - `WaitingForApproval`, `Open`: the ask's `amountMax`, reserved in the ledger's total, against both
    ///    identities unless both wallets are one identity's, and against the sender's away wallet on the token;
    ///  - `Cancelled`, `OnHold`, `Done`: none of the ask's reservation.
    ///  The release is read off the two rows, so it runs exactly once and is never skipped. A ticket is reserved
    ///  once, when it is written, so no move enters a row that holds more.
    function moveTo(ITickets.Ticket storage ticket, ITickets.TicketStatus next, address token) internal {
        bool oldRowHoldsTheAsk = _holdsTheAsk(ticket.status);
        bool newRowHoldsTheAsk = _holdsTheAsk(next);
        ticket.status = next;
        if (oldRowHoldsTheAsk && !newRowHoldsTheAsk) _release(ticket, ticket.amountMax, token);
    }

    /// @dev Whether a ticket in `status` holds the ask's reservation: the table of {moveTo}.
    function _holdsTheAsk(ITickets.TicketStatus status) private pure returns (bool) {
        return status == ITickets.TicketStatus.WaitingForApproval || status == ITickets.TicketStatus.Open;
    }

    /// @dev Gives back `amount` of what a ticket reserved: in the ledger's total, against the identities unless both
    ///  wallets are one identity's, and against the sending wallet on the token. {moveTo} gives back a whole row;
    ///  an approver's narrowing gives back part of it.
    function _release(ITickets.Ticket storage validation, uint256 amount, address token) private {
        ComplianceLedgerLib.Ledger storage ledger = ComplianceLedgerLib.layout();
        ledger.pendingTotal -= amount;
        if (!validation.relocation) {
            ledger.pendingOut[validation.fromIdentity] -= amount;
            ledger.pendingIn[validation.toIdentity] -= amount;
        }
        IToken(token).releaseFromTicket(validation.fromWallet, amount);
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
