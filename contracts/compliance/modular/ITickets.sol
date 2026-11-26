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

/**
 * @title ITickets
 * @dev The compliance's issuance surface for satellite movements: the two windows a COMPLIANCE_MANAGER tunes, the
 * per-chain issuance pause, the lifecycle of every issued validation and the keeper's discard. A satellite
 * executes a transfer only against a `TicketMessage` the reference chain issued for that exact transfer;
 * this is where it comes from. A ceiling on what may be issued is a rule, not a setting: a module answers it
 * from `checkTransfer`.
 */
interface ITickets {

    // The events and errors below are raised inside `TicketLib` and `ReceiptLib`, which
    // the compliance reaches by DELEGATECALL. They are declared again here so that they stay in the compliance's
    // ABI; each is documented where it is defined, in `EventsLib` and `ErrorsLib`.
    event TicketWritten(
        bytes32 indexed ticketId,
        bytes from,
        bytes to,
        bytes spender,
        uint256 amountMin,
        uint256 amountMax,
        uint256 requestedMax,
        uint64 validUntil,
        bytes32 askBlockHash,
        bytes32 salt
    );
    event ReceiptReceived(
        bytes32 indexed originChainKey, bytes32 indexed ticketId, bytes from, bytes to, uint256 amount
    );
    event ReceiptApplied(bytes32 indexed ticketId, bytes32 indexed chainKey, uint256 amount);
    event ReceiptDuplicate(bytes32 indexed ticketId, bytes32 indexed chainKey);
    event TicketCancelled(bytes32 indexed ticketId);
    event ReceiptWaiting(bytes32 indexed ticketId, bytes32 indexed chainKey, uint256 amount, bytes32 askBlockHash);
    event WaitingReceiptApplied(bytes32 indexed ticketId, bytes32 indexed chainKey);
    event ReceiptRefused(bytes32 indexed ticketId, bytes32 indexed chainKey, uint256 amount, bytes32 askBlockHash);
    event ReceiptOnOlderTerms(bytes32 indexed ticketId, bytes32 indexed chainKey, uint256 seenMax);
    event MoveBreachedRule(bytes32 indexed ticketId, bytes32 indexed chainKey, uint256 amount);
    event TicketLimitsSet(bytes32 indexed chainKey, uint256 perTicketCap, uint256 perWindowCap);

    error InvalidRequestedRange(uint256 requestedMin, uint256 requestedMax);
    error SenderNotOnSatellite(bytes wallet);
    error UnverifiedWallet(bytes wallet);
    error NotAuthorizedForWallet(address caller, bytes wallet);
    error EmptyValidationRange(uint256 min, uint256 max);
    error ZeroValue();
    error ValidationSpenderRefused(bytes spender);
    error TicketAlreadyWritten(bytes32 ticketId);
    error NoWaitingReceipt(bytes32 ticketId, bytes32 chainKey);
    error ApplyWaitingReceiptFirst(bytes32 ticketId, bytes32 chainKey);
    error TokenPaused();
    error TicketNotCancellable(bytes32 ticketId, uint8 status);
    error CancelNotDue(bytes32 ticketId, uint64 waitingEndsAt);
    error ValidationNotPubliclyDiscardable(bytes32 ticketId, uint64 publicAt);
    error ChainNotOpen(bytes32 chainKey);
    error UnknownTicket(bytes32 ticketId);
    error PerTicketCapLoweredTooEarly(bytes32 chainKey, uint64 allowedAt);
    error NonCanonicalInteroperableAddress(bytes envelope);
    error InteroperableAddressEmptyReferenceAndAddress();
    error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value);

    /// @dev What a ticket is for. Part of the ticket id, so a holder's move and an agent's bring home asked with the
    /// same wallet and salt never share an id.
    enum TicketKind {
        /// A holder's move out of an away wallet.
        MOVE,
        /// An agent's bring home of an away wallet.
        BRING_HOME
    }

    /// @dev Every state a ticket can be in. What each state keeps reserved is one table, see
    /// {TicketLib-moveTo}, so a release can neither run twice nor be skipped.
    enum TicketStatus {
        /// Written and reserved, sent nowhere: an `APPROVAL` module is bound and has not answered. `answerApproval`
        /// opens and sends it, or cancels it; past `validUntil`, `cancelTickets` cancels it.
        WaitingForApproval,
        /// Written, reserved and sent: waiting for its receipt.
        Open,
        /// Its reservation released: refused by the approver, or cancelled once its receipt was overdue. A late
        /// receipt for a ticket that was sent is still applied as the move it is.
        Cancelled,
        /// Money left a wallet and is held between two halves of a move.
        OnHold,
        /// The money is where it ends, or nothing moved.
        Done
    }

    /// @dev Everything the compliance keeps of an issued validation, keyed by its id and kept forever: every id
    /// stays classifiable against its stored status for good, which is what makes the emergency responses
    /// possible.
    ///
    /// The fields come in two groups: the terms of the move, written once, and the lifecycle: where the ticket
    /// stands and what the away token reported it moved.
    struct Ticket {
        /* ----- Written once, at issuance ----- */

        /// Names the copy of the ticket home sent, see {TicketLib-askBlockHashOf}. Zero until the ticket is
        /// issued and sent.
        bytes32 askBlockHash;
        /// Final inclusive lower bound, so a settlement's executed amount can be classified.
        uint256 amountMin;
        /// Final inclusive upper bound, what the reservation was taken at.
        uint256 amountMax;
        /// The satellite's hard deadline: no execution at or after it.
        uint64 validUntil;
        /// `validUntil` plus the waiting time: past it, the reservation may be released and the validation discarded.
        uint64 waitingEndsAt;
        /// `from`'s satellite chain, keyed as `MessageTypesLib.chainKey` computes it.
        bytes32 fromChainKey;
        /// Same for `to`'s chain; the reference chain's own key for a native wallet.
        bytes32 toChainKey;
        /// `keccak256` of the canonical `from` envelope: what a receipt's `from` is matched against.
        bytes32 fromKey;
        /// The sender's wallet envelope itself, kept so the reservation it holds on the token can be given back
        /// without the caller having to supply it again.
        bytes fromWallet;
        /// Same for `to`.
        bytes32 toKey;
        /// The identity `from` resolved to at issuance: whose pending amount was reserved and whose position
        /// settlement debits.
        address fromIdentity;
        /// Same for `to`. Equal to `fromIdentity` on a relocation between one identity's wallets.
        address toIdentity;

        /* ----- Moved by the lifecycle ----- */

        /// Both wallets belong to one identity, so nothing was ever reserved against the identities. Written
        /// once at issuance: it is the one thing the status cannot say on its own.
        bool relocation;
        /// Where the ticket stands. What is still reserved is read off this.
        TicketStatus status;
        /// What the away token reported it moved.
        uint256 moved;
        /// The spender the validation names, empty when `from` executes itself. Kept so the `AFTER` modules
        /// are told who executed it when it settles.
        bytes spender;

        /* ----- Written once, at issuance; last for the layout's sake ----- */

        /// The requester's nonce the id was derived from, carried in the issued body and kept for a resend.
        bytes32 salt;
        /// The upper bound as asked, before it was narrowed to `amountMax`: part of the id, and carried in the ticket.
        uint256 requestedMax;
    }

    /// @dev A receipt that arrived for a ticket written and not sent, kept so that once the ticket is sent
    /// `applyWaitingReceipt` can apply it. The delivery that carried it is consumed; this is all that is left of it.
    struct WaitingReceipt {
        /// ERC-7930 wallet the tokens left.
        bytes from;
        /// ERC-7930 wallet the tokens reached.
        bytes to;
        uint256 amount;
        /// The ask block hash of the ticket copy the Lite executed, as it reported it.
        bytes32 askBlockHash;
        /// Whether a receipt waits here, since every other field may legitimately be zero or empty.
        bool exists;
        /// The `amountMax` of the ticket copy the away token executed, as it reported it.
        uint256 seenMax;
        /// The `validUntil` of that copy, as it reported it.
        uint64 seenValidUntil;
    }

    /// @dev The caps on tickets toward one away chain.
    struct TicketLimits {
        /// The most one ticket toward the away chain may carry. A receipt on older terms whose `seenMax` is above it
        /// blocks the away chain.
        uint256 perTicketCap;
        /// The most the ticket route toward the away chain may carry in one window of one waiting time.
        uint256 perWindowCap;
    }

    /// @dev Issues a `TicketMessage` for a movement out of an away wallet, toward a wallet on the same away chain or
    /// a home wallet, and sends it to the sender's away chain through the token. A sender on
    /// the reference chain is refused: the Lite that executes a validation must physically hold the position it
    /// moves, where a native balance stays free to leave between issuance and settlement. The caller derives the
    /// requested range from an amount and a slippage tolerance; the range is only ever narrowed: capped at `from`'s
    /// bridged position less what is already pending out of it, then at the smallest `checkTransfer` answer any module
    /// answers (skipped when both wallets belong to one identity).
    ///
    /// The id is built from the whole request, see {TicketLib-ticketIdOf}: the kind, both wallets, the spender, the
    /// asked minimum and maximum, and the salt. Never from this chain's ordering or clock: the same request lands
    /// under the same id in whatever block and whatever order, so a ticket sent before this chain's finality keeps
    /// its id through a reorg. The requester chooses the salt; a salt reused for the same request is refused, which
    /// also refuses a replayed request instead of reserving twice. A request a reorg dropped is sent again with the
    /// same terms and salt, by the requester or by an agent reading the salt off the body the away token holds: it
    /// issues the same id, and the away token's receipt, delivered again, is applied on older terms, see
    /// {IReceiptHandler-receiveReceipt}.
    ///
    /// Requirements:
    /// - `requestedMin <= requestedMax`; otherwise reverts with `InvalidRequestedRange`.
    /// - The id of the request not yet recorded; otherwise reverts with `TicketAlreadyWritten`.
    /// - Both envelopes, and `spender` when given, canonical; otherwise `NonCanonicalInteroperableAddress`.
    /// - `from` on a satellite chain; otherwise reverts with `SenderNotOnSatellite`.
    /// - `to` at home or on `from`'s away chain; otherwise reverts with `ChainNotOpen` for `to`'s chain.
    /// - The caller is the identity `from` is linked to, or authorised by the AccessManager for this selector;
    ///   otherwise reverts with `NotAuthorizedForWallet`.
    /// - The token not paused; otherwise reverts with `TokenPaused`.
    /// - A validity window set, `from`'s chain not paused, and with a waiting time; otherwise
    ///   `ValidityWindowNotSet`, `ValidationIssuancePaused` or `WaitingTimeNotSet`.
    /// - `from`'s chain not blocked on the token; otherwise `AwayChainBlocked`.
    /// - `from` bound to an identity (revoked included) and `to` eligible; otherwise `UnverifiedWallet`.
    /// - A non-empty final range with a positive maximum; otherwise `EmptyValidationRange` or `ZeroValue`.
    /// - `from`'s chain open on the token; otherwise the token reverts with `ChainNotOpen`.
    ///
    /// Emits `TicketWritten`, then the token's `HalfPinned` and `ProtocolMessageSent`.
    ///
    /// While an `APPROVAL` module is bound, nothing is issued or sent yet: the validation is recorded and
    /// reserved as `WaitingForApproval`, `TicketWaitingForApproval` is emitted, the module is told, and
    /// `answerApproval` decides. The deadline for the answer is `validUntil`, the validity window from now, and it
    /// stays the satellite's deadline once the validation is issued.
    /// @param from ERC-7930 interoperable address of the sender.
    /// @param to ERC-7930 interoperable address of the recipient.
    /// @param requestedMin Inclusive lower bound the caller proposes.
    /// @param requestedMax Inclusive upper bound the caller proposes.
    /// @param spender ERC-7930 address allowed to execute through `transferFrom`, or empty for `from` alone.
    /// @param salt The requester's nonce for this movement; with the rest of the request, it is the id.
    /// @return ticketId The single-use id of the ticket, built from the whole request.
    function askToMove(
        bytes calldata from,
        bytes calldata to,
        uint256 requestedMin,
        uint256 requestedMax,
        bytes calldata spender,
        bytes32 salt
    ) external returns (bytes32 ticketId);

    /// @dev Answers a validation `WaitingForApproval`: issues it, at most at `approvedMax`, or refuses it. Only the
    /// bound `APPROVAL` module answers, before the deadline. A request nobody answered is discarded with
    /// `cancelTickets` once the deadline passed.
    ///
    /// An answer below the requested minimum is a refusal: the reservation is released and the validation ends
    /// `Cancelled`. Any other answer lowers the maximum to `approvedMax` when it is lower, releases the
    /// difference, and sends the ticket to the sender's away chain. No rule runs again: they ran at the
    /// request. The deadline stays the request's `validUntil`, so the time spent waiting comes out of the
    /// satellite's time to execute, and the rules are never older than the validity window when it does.
    ///
    /// Requirements:
    /// - `ticketId` must have been issued; otherwise reverts with `UnknownTicket`.
    /// - It must be stored `WaitingForApproval`; otherwise reverts with `ValidationNotAwaitingApproval`.
    /// - The caller must be the bound `APPROVAL` module; otherwise reverts with `NotTheApprovalModule`.
    /// - `block.timestamp` must be before `validUntil`; otherwise reverts with `ValidationExpired`.
    /// - On an approval, the token not paused, otherwise `TokenPaused`, and the sender's chain still open,
    ///   configured and not paused, as at a request.
    ///
    /// Emits `TicketWritten` and sends the ticket, unless a receipt for it already waits here, as `askToMove`
    /// does, or emits `ValidationApprovalRefused`.
    /// @param ticketId The validation awaiting approval.
    /// @param approvedMax The largest amount approved; below the requested minimum, a refusal.
    function answerApproval(bytes32 ticketId, uint256 approvedMax) external;

    /// @dev Sets how long a validation stays executable on the satellite: `validUntil` is issuance time plus this.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - `duration` must not be zero; otherwise reverts with `ZeroDuration`.
    ///
    /// Emits `DefaultValidityWindowSet`.
    /// @param duration The validity window in seconds.
    function setDefaultValidityWindow(uint64 duration) external;

    /// @dev Sets how long T-REX keeps a reservation past `validUntil` for a ticket to that chain. Snapshot at issuance,
    /// so a later change never moves an outstanding deadline.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - `duration` must not be zero; otherwise reverts with `ZeroDuration`.
    ///
    /// Emits `WaitingTimeSet`.
    /// @param chainKey The chain, keyed as `MessageTypesLib.chainKey` computes it.
    /// @param duration The window in seconds.
    function setWaitingTime(bytes32 chainKey, uint64 duration) external;

    /// @dev Stops or resumes issuing tickets involving `chainKey`. Setting the state it already has changes
    /// nothing and emits nothing.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    ///
    /// Emits `ValidationIssuancePaused` or `ValidationIssuanceUnpaused` when the state changes.
    /// @param chainKey The chain, keyed as `MessageTypesLib.chainKey` computes it.
    /// @param paused Whether issuance toward or from the chain is paused.
    function setIssuancePaused(bytes32 chainKey, bool paused) external;

    /// @dev Sets the caps on tickets toward the away chain `chainKey`. A receipt on older terms whose `seenMax` is
    /// above the per-ticket cap blocks that away chain. Raising a cap takes effect at once. Lowering the per-ticket
    /// cap waits until the latest valid until of a ticket sent toward the chain has passed: an honest copy sent under
    /// the higher cap would otherwise echo a `seenMax` above the new one and block an honest chain. The per-window
    /// cap is kept for the route each ticket takes.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - A lower per-ticket cap only from the latest valid until sent toward `chainKey`; otherwise reverts with
    ///   `PerTicketCapLoweredTooEarly`.
    ///
    /// Emits `TicketLimitsSet`.
    /// @param chainKey The away chain, keyed as `MessageTypesLib.chainKey` computes it.
    /// @param perTicketCap The most one ticket toward the chain may carry.
    /// @param perWindowCap The most the ticket route toward the chain may carry in one window of one waiting time.
    function setTicketLimits(bytes32 chainKey, uint256 perTicketCap, uint256 perWindowCap) external;

    /// @dev Cancels overdue tickets in a batch: releases their reservations, so the next ask is computed as if
    /// they never happened. From `waitingEndsAt` the keeper may cancel; from the end of the second window, one more
    /// waiting time past `waitingEndsAt`, anyone may. A receipt that lands after the cancel is still applied as the
    /// move it is. The batch is atomic: one refused id reverts the whole call.
    ///
    /// A cancel cannot know whether the away token executed the ticket before its deadline: the away token reports
    /// only what it executed. If it did and the receipt is still in flight, the wallet's room is given back early, a
    /// newer ticket may reserve it, and the late receipt still debits the wallet when it lands. Set each chain's
    /// waiting time above the longest delivery delay its bridge can have, so a receipt this late is not expected.
    ///
    /// Requirements:
    /// - Each id must have been issued; otherwise reverts with `UnknownTicket`.
    /// - A ticket `WaitingForApproval` may be cancelled by anyone once its `validUntil` passed, since nothing was
    ///   sent for it; otherwise reverts with `CancelNotDue`. The rules below do not apply to it.
    /// - Each other id must be stored `Open`; otherwise reverts with `TicketNotCancellable`.
    /// - `block.timestamp` must be past each id's `waitingEndsAt`; otherwise reverts with `CancelNotDue`.
    /// - A caller without the role bound to this selector needs `block.timestamp` past each id's second window;
    ///   otherwise reverts with `ValidationNotPubliclyDiscardable`.
    /// - The token not paused; otherwise reverts with `TokenPaused`: every receipt waits at its bridge under the
    ///   pause, so the one that answers the ticket may be among them.
    /// - The sender's away chain not blocked on the token; otherwise reverts with `AwayChainBlocked`: the receipts
    ///   held at that bridge may answer the ticket.
    /// - The sender's away chain open on the token: a receipt route set, through a bridge still recorded as a
    ///   receipt bridge; otherwise reverts with `ChainNotOpen`. Its receipt cannot land meanwhile, so it is not
    ///   taken as missing.
    /// - No receipt waiting under an id; otherwise reverts with `ApplyWaitingReceiptFirst`: the receipt is already
    ///   here, and {applyWaitingReceipt} applies it first.
    ///
    /// Emits `TicketCancelled` per id.
    /// @param validationIds The tickets to cancel.
    function cancelTickets(bytes32[] calldata validationIds) external;

    /// @dev Sends an open ticket to the sender's away chain again, byte for byte, through the bridge the first send
    /// pinned. The way to recover a ticket the bridge lost before its valid until, instead of waiting for
    /// `waitingEndsAt` and asking again. `to` is the one envelope the record does not keep; it is read off
    /// `TicketWritten`, like `spender`, and both must be the ones the ticket was asked with, so a resend can neither
    /// widen nor retarget the move. The copy sent is the one recorded, ask block hash included. Nothing is written.
    ///
    /// Requirements:
    /// - `ticketId` must have been issued; otherwise reverts with `UnknownTicket`.
    /// - `chainKey` must be the sender's chain; otherwise reverts with `ChainNotPartOfValidation`.
    /// - It must be stored `Open`; otherwise reverts with `ValidationNotResendable`.
    /// - `block.timestamp` must be before `validUntil`; otherwise reverts with `ValidationExpired`: past it no away
    ///   token may execute.
    /// - The token must not be paused; otherwise reverts with `TokenPaused`.
    /// - Issuance toward `chainKey` must not be paused; otherwise reverts with `ValidationIssuancePaused`.
    /// - `chainKey` must not be blocked on the token; otherwise reverts with `AwayChainBlocked`.
    /// - `to` must have the recorded key and `spender` must be the recorded spender; otherwise reverts with
    ///   `ValidationBodyMismatch`.
    /// - The caller is the identity `from` is linked to, the identity `to` is linked to when `to` is on the same
    ///   away chain, or authorised by the AccessManager for this selector; otherwise reverts with
    ///   `NotAuthorizedForWallet`.
    /// - The pinned bridge and peer must still be the chain's route and peer; otherwise the token reverts with
    ///   `ValidationAlreadyRouted`. The ticket then returns its reservation through a cancel at `waitingEndsAt`.
    ///
    /// Nothing counts or spaces resends. The token forwards no value to the bridge, so a resend costs its caller
    /// the gas and whatever the bridge charges, and the away token ignores a copy it already holds.
    ///
    /// Emits `TicketSent`, then the token's `ProtocolMessageSent`.
    /// @param ticketId The ticket sent again.
    /// @param chainKey The sender's away chain, keyed as `MessageTypesLib.chainKey` computes it.
    /// @param to ERC-7930 interoperable address of the recipient, as issued.
    /// @param spender ERC-7930 address of the spender, as issued, or empty.
    function sendTicket(bytes32 ticketId, bytes32 chainKey, bytes calldata to, bytes calldata spender) external;

    /// @dev The window added to the issuance timestamp to compute `validUntil`. Zero until set, which blocks issuance.
    function defaultValidityWindow() external view returns (uint64);

    /// @dev The waiting time configured for `chainKey`, zero when unset, which blocks issuance.
    /// @param chainKey The chain to look up.
    function waitingTimeOf(bytes32 chainKey) external view returns (uint64);

    /// @dev Whether issuance is paused for movements involving `chainKey`.
    /// @param chainKey The chain to look up.
    function isIssuancePaused(bytes32 chainKey) external view returns (bool);

    /// @dev The caps on tickets toward `chainKey`, zero until set.
    /// @param chainKey The away chain to look up.
    function ticketLimitsOf(bytes32 chainKey) external view returns (TicketLimits memory);

    /// @dev Applies the receipt `chainKey` sent for `ticketId` while the ticket was written and not sent, once it is
    /// sent. The receipt is applied exactly as it would have been at delivery, see {IReceiptHandler-receiveReceipt}:
    /// `WaitingReceiptApplied` is emitted, or, when it breaks its terms, the away chain is blocked through
    /// `IToken.applyVerdict`. Its own call, for anyone, rather than a step of the send: a receipt that reverts here,
    /// a tracker module that refuses it for instance, stays waiting and can be tried again.
    ///
    /// Requirements:
    /// - A receipt must wait under `(ticketId, chainKey)` and the ticket be sent (its ask block hash written);
    ///   otherwise reverts with `NoWaitingReceipt`.
    /// - The token must not be paused; otherwise reverts with `TokenPaused`. A delivered receipt waits under the
    ///   pause the same way.
    /// - `chainKey` must not be blocked on the token; otherwise reverts with `AwayChainBlocked`.
    ///
    /// Emits `WaitingReceiptApplied`, or the block of the away chain.
    /// @param ticketId The ticket the waiting receipt belongs to.
    /// @param chainKey The chain the receipt came from, keyed as `MessageTypesLib.chainKey` computes it.
    function applyWaitingReceipt(bytes32 ticketId, bytes32 chainKey) external;

    /// @dev The receipt `chainKey` sent for `ticketId` while the ticket was written and not sent, `exists` false when
    /// none waits. Applied by `applyWaitingReceipt` once the ticket is sent; left waiting for good when it is
    /// refused or never answered.
    /// @param ticketId The ticket to look up.
    /// @param chainKey The chain the receipt came from, keyed as `MessageTypesLib.chainKey` computes it.
    function waitingReceiptOf(bytes32 ticketId, bytes32 chainKey) external view returns (WaitingReceipt memory);

    /// @dev Everything kept for `ticketId`, all zeros when the id was never issued.
    /// @param ticketId The validation to look up.
    function ticketOf(bytes32 ticketId) external view returns (Ticket memory);

    /// @dev Where `ticketId` stands.
    ///
    /// Requirements:
    /// - `ticketId` must have been taken; otherwise reverts with `UnknownTicket`.
    /// @param ticketId The validation to look up.
    function statusOf(bytes32 ticketId) external view returns (TicketStatus);

}
