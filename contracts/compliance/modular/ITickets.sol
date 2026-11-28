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

import { MessageTypesLib } from "../../libraries/MessageTypesLib.sol";

/**
 * @title ITickets
 * @dev The compliance's surface for moves between chains: the validity windows, waiting times, measured times and
 * limits a COMPLIANCE_MANAGER tunes, the block of an away chain, the receipts waiting to be applied, the lifecycle of
 * every ticket, the ask for its receipt and its cancel. An away token executes a move only against a `TicketMessage`
 * home wrote for that exact move; this is where it comes from. A ceiling on what may be issued is a rule, not a setting: a module answers it
 * from `checkTransfer`.
 */
interface ITickets {

    // The events and errors below are raised inside `TicketLib`, `ReceiptLib`, `SecondHalfLib` and `HoldLib`, which
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
    event ReceiptWaiting(
        bytes32 indexed halfKey, bytes32 indexed chainKey, address bridge, MessageTypesLib.ReceiptMessage receipt
    );
    event WaitingReceiptApplied(bytes32 indexed halfKey, bytes32 indexed chainKey);
    event WaitingReceiptRefused(bytes32 indexed halfKey);
    event AwayChainBlockSet(bytes32 indexed chainKey, bool blocked);
    event ReceiptRefused(
        bytes32 indexed ticketId, bytes32 indexed chainKey, uint256 amount, bytes32 askBlockHash, ReceiptRefusal reason
    );
    event ReceiptOnOlderTerms(bytes32 indexed ticketId, bytes32 indexed chainKey, uint256 seenMax);
    event MoveBreachedRule(bytes32 indexed ticketId, bytes32 indexed chainKey, uint256 amount);
    event TicketLimitsSet(bytes32 indexed chainKey, uint256 perTicketCap, uint256 perWindowCap);
    event ValidityWindowsSet(uint64 onTicketRoute, uint64 onReceiptRoute);
    event WaitingTimeSet(bytes32 indexed chainKey, uint64 duration);
    event MeasuredTimesSet(bytes32 indexed chainKey, MeasuredTimes times);
    event AsksPausedSet(bytes32 indexed chainKey, bool paused);
    event AskLimitsSet(AskLimits limits);
    event AskLimitOfSet(address indexed identity, uint32 asksPerWindow);
    event ReceiptAsked(bytes32 indexed ticketId, uint8 askNumber);
    event TicketStillOpen(bytes32 indexed ticketId, uint64 seenValidUntil);
    event SecondHalfSent(
        bytes32 indexed ticketId, uint8 half, bytes32 indexed chainKey, bytes wallet, uint256 amount, uint64 validUntil
    );
    event SecondHalfNotSent(bytes32 indexed ticketId, uint8 half);
    event ReceiptWithoutTicket(
        bytes32 indexed ticketId, bytes32 indexed chainKey, bytes from, bytes to, uint256 amount
    );
    event ReceiptUnknown(bytes32 indexed halfKey, bytes32 indexed chainKey);
    event HoldTaken(bytes32 indexed ticketId);
    event CancelHoldShort(bytes32 indexed ticketId, uint256 missing);
    event ClosedByHand(bytes32 indexed ticketId, uint256 returnedAmount, uint64 awayBlockNumber, uint64 awayClockTime);

    error SpenderNotAllowed(address spender, address from, address to, uint256 value);
    error NotACrossChainMove();
    error FrozenWallet(address user);
    error SecondHalfNotOwed(bytes32 ticketId);
    error NoNewHalfLeft(bytes32 ticketId);
    error NotEnoughGasForTheSecondHalf(uint256 left, uint256 needed);
    error ValidationBodyMismatch(bytes32 ticketId);
    error UnverifiedWallet(bytes wallet);
    error NotAuthorizedForWallet(address caller, bytes wallet);
    error EmptyValidationRange(uint256 min, uint256 max);
    error ZeroValue();
    error ValidationSpenderRefused(bytes spender);
    error TicketAlreadyWritten(bytes32 ticketId);
    error NoWaitingReceipt(bytes32 halfKey);
    error AwayChainNotBlocked(bytes32 chainKey);
    error AwayChainBlocked(bytes32 chainKey);
    error HostileChangeNotOver(bytes32 chainKey, uint64 endsAt);
    error InsufficientBridgedBalance(bytes wallet, uint256 balance, uint256 needed);
    error ApplyWaitingReceiptFirst(bytes32 ticketId, bytes32 chainKey);
    error TokenPaused();
    error TicketNotCancellable(bytes32 ticketId, uint8 status);
    error CancelNotDue(bytes32 ticketId, uint64 dueAt);
    error NoAsksLeft(bytes32 ticketId);
    error SendNotDue(bytes32 ticketId, uint64 dueAt);
    error WaitingTimeTooShort(bytes32 chainKey, uint64 duration, uint64 mustBeAbove);
    error ValidityWindowOutOfRange(uint64 duration, uint64 mustBeAtMost);
    error AsksPaused();
    error AsksNotPaused();
    error AskLimitReached(address identity);
    error TooManyOpenTickets(address identity);
    error BelowMinimumAmount(uint256 requestedMax, uint256 smallestAmount);
    error RequestAboveBalance(bytes wallet, uint256 free, uint256 requestedMax);
    error ZeroDuration();
    error ChainNotOpen(bytes32 chainKey);
    error UnknownTicket(bytes32 ticketId);
    error NonCanonicalInteroperableAddress(bytes envelope);
    error InteroperableAddressEmptyReferenceAndAddress();
    error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value);
    error WalletsNotLinked(address nativeWallet, bytes wallet);
    error BringHomeAlreadyOpen(bytes32 walletKey, bytes32 ticketId);
    error WaitingTimeNotSet(bytes32 chainKey);
    error NotASatelliteWallet(bytes wallet);
    error LaterHoldStillCarries(bytes32 ticketId, bytes32 laterTicketId);
    error HeldReceiptBreaksItsTerms(bytes32 ticketId);
    error AwayClockBeforeValidUntil(bytes32 ticketId, uint64 awayClockTime, uint64 validUntil);
    error ReceiptRouteNotClosed(bytes32 chainKey);

    /// @dev Why a receipt was refused as bad, announced in `ReceiptRefused`. The design's reasons first.
    enum ReceiptRefusal {
        /// A second, different body under one half, applied or waiting.
        AnotherBody,
        /// It comes from a chain that is not the one the half or the ticket went to, or its sender is not on it.
        WrongChain,
        /// It names wallets that are not the ticket's or the second half's, or a receiver that is not a wallet.
        WrongWallets,
        /// It names a half home never sent: above the ticket's latest half, or the latest one before it left.
        HalfNotSent,
        /// A move-out receipt different from its move out.
        WrongMoveOut,
        /// A bring-home receipt above its bring home, or for a half that cannot burn any more.
        AboveTheBringHome,
        /// A still open answer on home's own ask block hash with another valid until.
        AnotherValidUntil
    }

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
        /// opens it, or cancels it; past `validUntil`, `cancelTickets` cancels it.
        WaitingForApproval,
        /// Written, reserved and sent: waiting for its receipt. Or opened by the approver and not sent yet: anyone
        /// sends it with `sendTicket`, at any time; `cancelTickets` cancels it only once an ask went unanswered, or,
        /// for a home `from`, which never has an ask, past `validUntil`.
        Open,
        /// Its reservation released: refused by the approver, or cancelled once its receipt was overdue. A late
        /// receipt for a ticket that was sent is still applied as the move it is.
        Cancelled,
        /// Money left a wallet and is held between two halves of a move: the away chain burned it, or a home wallet
        /// that moves out burned it at home. `secondHalfToKey` says where it goes: the receiver, or back to the sender.
        OnHold,
        /// The money is where it ends, or nothing moved.
        Done
    }

    /// @dev Everything the compliance keeps of a ticket, keyed by its id and kept forever: every id
    /// stays classifiable against its stored status for good, which is what makes the emergency responses
    /// possible.
    ///
    /// The fields come in two groups: the terms of the move, written once, and the lifecycle: where the ticket
    /// stands and what the away token reported it moved.
    struct Ticket {
        /* ----- Written once, at issuance ----- */

        /// Names the copy of the ticket home wrote, see {TicketLib-askBlockHashOf}: the ask's own block. For a record a
        /// receipt created, the one the receipt echoed.
        bytes32 askBlockHash;
        /// Final inclusive lower bound, so a receipt's executed amount can be judged.
        uint256 amountMin;
        /// Final inclusive upper bound, what the reservation was taken at. For a record a receipt created: the maximum
        /// the receipt echoed, then, once its money on hold is being cancelled, what the cancel's latest half moves.
        uint256 amountMax;
        /// The away token's hard deadline: no execution at or after it.
        uint64 validUntil;
        /// `from`'s away chain, keyed as `MessageTypesLib.chainKey` computes it.
        bytes32 fromChainKey;
        /// Same for `to`'s chain; home's own key for a home wallet.
        bytes32 toChainKey;
        /// `keccak256` of the canonical `from` envelope: what a receipt's `from` is matched against.
        bytes32 fromKey;
        /// The sender's wallet envelope itself, kept so the reservation it holds on the token can be given back
        /// without the caller having to supply it again.
        bytes fromWallet;
        /// Same for `to`.
        bytes32 toKey;
        /// The identity `from` resolved to at the ask: whose pending amount was reserved and whose total owned the
        /// receipt debits.
        address fromIdentity;
        /// Same for `to`. Equal to `fromIdentity` on an internal move between one identity's wallets.
        address toIdentity;

        /* ----- Moved by the lifecycle ----- */

        /// Both wallets belong to one identity, so nothing was ever reserved against the identities. Written
        /// once at issuance: it is the one thing the status cannot say on its own.
        bool relocation;
        /// Where the ticket stands. What is still reserved is read off this.
        TicketStatus status;
        /// What the away token reported it moved, or what a home wallet that moves out burned: the money on hold
        /// while the ticket is `OnHold`.
        uint256 moved;
        /// The spender the ticket names, empty when `from` executes itself. Kept so the `AFTER` modules
        /// are told who executed it when it settles.
        bytes spender;

        /* ----- Written once, at issuance; last for the layout's sake ----- */

        /// The requester's nonce the id was derived from, carried in the issued body and kept for an ask for the
        /// receipt.
        bytes32 salt;
        /// The upper bound as asked, before it was narrowed to `amountMax`: part of the id, and carried in the ticket.
        uint256 requestedMax;

        /* ----- The clock; last for the layout's sake ----- */

        /// The latest valid until the away token reported in a still open answer, within home's cap; zero when none.
        /// The asks and the cancel count from the later of it and `validUntil`.
        uint64 seenValidUntil;
        /// `validUntil` plus four waiting times, fixed at the ask: home stops waiting for this ticket then.
        uint64 stopWaitingAt;
        /// When the ticket last left home: its first send, then each ask for its receipt.
        uint64 lastSentAt;
        /// The asks for the receipt that stand; a still open answer that moves valid until gives one back.
        uint8 asksForReceipt;

        /* ----- The second half, while the money is on hold; last for the layout's sake ----- */

        /// The number of the latest second half, from 1; zero while the ticket has none.
        uint8 half;
        /// The key of the wallet the second half mints to: the receiver's on a forward move, the sender's on a return.
        bytes32 secondHalfToKey;
        /// The latest second half's valid until: its first send time plus the waiting time of its chain.
        uint64 secondHalfValidUntil;
        /// How many times the latest second half was sent, at most `MAX_SENDS_PER_HALF`. Zero when it never left.
        uint8 secondHalfSends;
        /// The latest second half is dead, answered zero after its valid until, or its send failed: anyone sends the
        /// next one with `sendSecondHalf`.
        bool secondHalfOwed;
        /// How many second halves this money on hold has had, at most `MAX_NEW_HALVES`.
        uint8 newHalves;

        /* ----- What the ticket is for; last for the layout's sake ----- */

        /// A holder's move, or an agent's bring home.
        TicketKind kind;
        /// The home wallet a bring home mints to; zero for a move. Kept because the bring home's receipt names only
        /// the wallet it burned.
        address homeWallet;

        /* ----- Money on hold with no ticket; last for the layout's sake ----- */

        /// A ticket home sent answers this record. False for a record a receipt created: an id home has no record
        /// of, or a ticket home wrote and never sent. Only such a record may be taken by the ask mined again.
        bool written;
        /// The earlier money on hold whose uncounted credit this one carries: the sender spent tokens home does not
        /// count for it yet. Zero when none.
        bytes32 carriedFrom;
        /// How much of this money on hold is the earlier one's uncounted credit, not yet the sender's own.
        uint256 carriedAmount;
        /// The later money on hold that carries this one's uncounted credit; zero when none. This one is not
        /// cancelled before that one gives the credit back.
        bytes32 carriedBy;
        /// The cancel of this money on hold burned less than it asked: the rest stays on hold and is not sent again
        /// until carried credit comes back to the receiver.
        bool shortCancel;

        /* ----- The route, chosen at the ask; last for the layout's sake ----- */

        /// The ticket and every ask for its receipt travel the receipt route, at full finality: it waited for an
        /// approver, it is above a cap, or its chain has no trusted ticket bridge. Never chosen again.
        bool onReceiptRoute;
        /// An approval module was bound at the ask, so the ticket waited for its answer. Its only honest copy is
        /// home's own: a first-half receipt on any other ask block hash breaks its terms.
        bool waitedForApproval;

        /* ----- The return of a move; last for the layout's sake ----- */

        /// The number of the last second half sent to the receiver before close by hand turned the money on hold
        /// back to the sender; zero when none was. An older half's late answer is judged against the receiver.
        uint8 lastHalfToTheReceiver;

        /* ----- The first send; last for the layout's sake ----- */

        /// The ticket left for the away chain: written at its first send. A ticket waiting for approval, or opened
        /// and not sent yet, has none.
        bool sent;

        /* ----- The stage of a cancel of money on hold with no ticket; last for the layout's sake ----- */

        /// The cancel's latest half is the move out back to the sender, of what burned; false while its bring home
        /// is out or owed. Its own field: a wallet that moved to itself is both the wallet the bring home burns and
        /// the one the move out mints to.
        bool cancelReturnsToTheSender;
    }

    /// @dev A good receipt that could not be applied when it arrived, kept under its half until anyone applies it
    /// with `applyWaitingReceipt`. The delivery that carried it is consumed. Home keeps its hash, not its bytes: the
    /// caller gives the receipt back from `ReceiptWaiting`, and the hash proves it. The bridge and the peer that
    /// delivered it are kept so the route check runs again on them when it is applied.
    struct WaitingReceipt {
        /// `keccak256(abi.encode(chainKey, receipt))`, the hash a receipt is known by under its half. Zero when
        /// nothing waits.
        bytes32 bodyHash;
        /// The away chain the receipt came from.
        bytes32 chainKey;
        /// The bridge that delivered it.
        address deliveredBy;
        /// The `keccak256` of the peer that sent it.
        bytes32 peerKey;
        /// What it moved, so a cancel can tell whether the sender's away balance covers it now.
        uint256 amount;
        /// When it was delivered, so the route check run again takes the former pair it came on inside its window.
        uint64 arrivedAt;
    }

    /// @dev The two validity windows: a ticket is valid until the ask's time plus the window of the route it travels.
    struct ValidityWindows {
        /// For a ticket on the ticket route. It must cover a delivery at full finality whenever the ticket bridge
        /// can run at full finality: before the rollout gates are live, and during a health gate trip.
        uint64 onTicketRoute;
        /// For a ticket on the receipt route, sent at full finality, which takes longer to arrive.
        uint64 onReceiptRoute;
    }

    /// @dev The times measured for one away chain, in seconds: the floor of its waiting time, the cap of a still
    /// open answer, and the shift a cancel on its closed route waits for.
    struct MeasuredTimes {
        /// How far this chain's clock may run ahead of home's.
        uint64 clockLead;
        /// The longest delivery to this chain at full finality.
        uint64 fullFinalityDelivery;
        /// How far an ask mined again after a home reorg may move in time, under a minute on Ethereum.
        uint64 reorgSlotShift;
    }

    /// @dev The limits on asks, for the whole token.
    struct AskLimits {
        /// The most tickets one identity may have waiting for approval or open at once.
        uint32 openTicketsPerIdentity;
        /// The most asks one identity may make in one `askWindow`, unless it has its own limit.
        uint32 asksPerIdentityPerWindow;
        /// The length of the window asks are counted over, in seconds.
        uint64 askWindow;
        /// The smallest maximum one may ask to move.
        uint256 smallestAmount;
    }

    /// @dev The caps on tickets toward one away chain.
    struct TicketLimits {
        /// The most one ticket toward the away chain may carry. A receipt on older terms whose `seenMax` is above it
        /// blocks the away chain.
        uint256 perTicketCap;
        /// The most the ticket route toward the away chain may carry in one window of one waiting time.
        uint256 perWindowCap;
    }

    /// @dev What a human read from an away chain whose receipt route is closed, all from one final block of that
    /// chain, at or after the valid until of the half or the ticket being closed. The role that may close by hand
    /// attests it; nothing on chain proves it.
    struct AwayChainReading {
        /// The number of the final block read.
        uint64 blockNumber;
        /// That block's timestamp: the away chain's own clock.
        uint64 awayClockTime;
        /// The receipt the away token stored for the half, as it would have sent it; an amount of zero when it
        /// stored none, or stored that nothing moved.
        MessageTypesLib.ReceiptMessage storedReceipt;
        /// The valid until of the ticket copy the away token holds for an open ticket; zero when it holds none.
        uint64 storedTicketValidUntil;
    }

    /// @dev Asks to move tokens between chains. From an away wallet, toward any wallet: issues a `TicketMessage` and
    /// sends it to the sender's away chain only, through the token. When the receiver is on another chain, home puts
    /// the amount on hold once the receipt lands, asks the rules again for the receiver and sends the second half, a
    /// `MOVE_OUT`, to the receiver, or back to the sender when the rules refuse it. From a home wallet, toward an
    /// away wallet: the same move with no first half, done in this transaction: the amount is burned at home and put
    /// on hold, and the `MOVE_OUT` leaves at once. The caller derives the requested range from an amount and a
    /// slippage tolerance. The asked maximum must fit in `from`'s free balance, since the id is built from it; the
    /// range is then only ever narrowed, to the smallest `checkTransfer` answer any module answers (skipped when both
    /// wallets belong to one identity); a home wallet moves out that narrowed maximum. The ticket is valid for the
    /// validity window of the route it travels, see {setValidityWindows}.
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
    /// When a receipt for this id came first and its money is on hold with no ticket, the ask takes it, right after
    /// the id is built and the caller checked: the move the away token made is finished, and none of the requirements
    /// below on limits, windows, balances or amounts is asked. A move inside one away chain is then applied when the
    /// receiver is verified and the rules allow it now, and its hold is cancelled otherwise, see {cancelHold}; a move
    /// out of the away chain is decided as a first-half receipt is. The take is refused while an approval module is
    /// bound (`TicketAlreadyWritten`), while the token is paused, the sender's chain blocked or a hostile change runs
    /// on it, while the hold carries an earlier hold's credit (`LaterHoldStillCarries`: the tokens spent are not the
    /// sender's yet), and when the held receipt names other wallets than the ask (`HeldReceiptBreaksItsTerms`). A held
    /// receipt that breaks the terms of the ask or the away chain's per-ticket cap is still taken as it happened, and
    /// blocks the sender's chain (`AwayChainBlockSet`). Emits `HoldTaken`.
    ///
    /// Requirements:
    /// - Asks not paused for every chain, nor for `from`'s chain or `to`'s chain; otherwise reverts with
    ///   `AsksPaused`.
    /// - `requestedMin <= requestedMax`; otherwise reverts with `EmptyValidationRange(requestedMin, requestedMax)`.
    /// - The id of the request not yet recorded, or money on hold the ask may take; otherwise reverts with
    ///   `TicketAlreadyWritten`.
    /// - Both envelopes, and `spender` when given, canonical; otherwise `NonCanonicalInteroperableAddress`.
    /// - `from` and `to` not both home wallets; otherwise reverts with `NotACrossChainMove`.
    /// - No spender for a home `from`; otherwise reverts with `SpenderNotAllowed(spender, from, 0, requestedMax)`,
    ///   the spender as a home address, or zero when it is an away wallet.
    /// - The caller is the identity an away `from` is linked to, a home `from` itself (never its identity), or
    ///   authorised by the AccessManager for this selector; otherwise reverts with `NotAuthorizedForWallet`. Every ask counts in the limits of `from`'s
    ///   identity, a home wallet's included.
    /// - The token not paused; otherwise reverts with `TokenPaused`.
    /// - A validity window set, and the chain the first message goes to with a waiting time; otherwise
    ///   `ValidityWindowNotSet` or `WaitingTimeNotSet`. That chain is `from`'s, or `to`'s for a home `from`.
    /// - That chain not blocked; otherwise `AwayChainBlocked`.
    /// - No hostile change running on that chain, see {ITREXMessaging-hostileChangeEndsAt}; otherwise
    ///   `HostileChangeNotOver`.
    /// - The sender's identity below its open tickets and its asks in the current window; otherwise
    ///   `TooManyOpenTickets` or `AskLimitReached`. A take of money on hold is an ask too: it is refused over the asks
    ///   in the window (`AskLimitReached`) and counted there, but not as an open ticket.
    /// - `from` bound to an identity (revoked included) and `to` eligible; otherwise `UnverifiedWallet`.
    /// - `requestedMax` at least the smallest amount, and at most `from`'s free balance: its away balance less what
    ///   is reserved, or a home wallet's unfrozen balance; otherwise `BelowMinimumAmount` or `RequestAboveBalance`.
    /// - A non-empty final range with a positive maximum; otherwise `EmptyValidationRange` or `ZeroValue`.
    /// - A home `from` not frozen; otherwise `FrozenWallet`.
    /// - The chain the first message goes to open on the token, a receipt route with a peer, checked at the ask even
    ///   when it waits for approval; otherwise `ChainNotOpen`.
    /// - For a receiver on another away chain, that chain too not blocked, with no hostile change running, with a
    ///   waiting time, and open on the token; otherwise `AwayChainBlocked`, `HostileChangeNotOver`,
    ///   `WaitingTimeNotSet` or `ChainNotOpen`.
    ///
    /// Emits `TicketWritten`, then the token's `HalfPinned` and `ProtocolMessageSent`. For a home `from`: the token's
    /// `HeldInTransit` and `Transfer`, `SecondHalfSent`, then the token's `HalfPinned` and `ProtocolMessageSent`.
    ///
    /// The route is chosen here and written on the ticket, see {Ticket-onReceiptRoute}: the receipt route, at full
    /// finality, while an `APPROVAL` module is bound, for a home `from`, when the chain has no trusted ticket bridge,
    /// above the chain's per-ticket cap, or when the ticket would take the ticket route above its per-window cap in
    /// the current window of one waiting time; the ticket route otherwise. `validUntil` is the ask's time plus the
    /// validity window of that route.
    ///
    /// While an `APPROVAL` module is bound, nothing is issued or sent yet: the ticket is recorded and
    /// reserved as `WaitingForApproval`, `TicketWaitingForApproval` is emitted, the module is told, and
    /// `answerApproval` decides. The deadline for the answer and for the first send is `validUntil`, and it stays
    /// the away token's deadline once the ticket is sent.
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

    /// @dev Answers a ticket `WaitingForApproval`: issues it, at most at `approvedMax`, or refuses it. Only the
    /// bound `APPROVAL` module answers, before the deadline. A request nobody answered is discarded with
    /// `cancelTickets` once the deadline passed.
    ///
    /// A zero is a refusal: the reservation is released and the ticket ends `Cancelled`. An answer inside
    /// `[amountMin, amountMax]` lowers the maximum to `approvedMax` when it is lower, releases the difference, and
    /// opens the ticket: nothing is sent, anyone makes the first send with `sendTicket`, so the
    /// approver never pays for a send. No rule runs again: they ran at the request. The deadline stays the
    /// request's `validUntil`, so the time spent waiting comes out of the away token's time to execute, and the
    /// rules are never older than the validity window when it does.
    ///
    /// Requirements:
    /// - `ticketId` must have been issued; otherwise reverts with `UnknownTicket`.
    /// - It must be stored `WaitingForApproval`; otherwise reverts with `NotWaitingForApproval`.
    /// - The caller must be the bound `APPROVAL` module; otherwise reverts with `NotTheApprovalModule`.
    /// - `block.timestamp` must be before `validUntil`; otherwise reverts with `ValidationExpired`.
    /// - `approvedMax` zero or inside `[amountMin, amountMax]`; otherwise reverts with
    ///   `EmptyValidationRange(amountMin, amountMax)`, the range an answer must fall in.
    ///
    /// Emits nothing on an approval (`TicketWritten` comes with the first send), or `ValidationApprovalRefused`.
    /// @param ticketId The ticket awaiting approval.
    /// @param approvedMax The largest amount approved; zero, a refusal.
    function answerApproval(bytes32 ticketId, uint256 approvedMax) external;

    /// @dev Sets the two validity windows: a ticket is valid until the ask's time plus the window of the route it
    /// travels. A ticket at full finality takes longer to arrive, so it needs the longer window. The ticket route's
    /// bridge runs at full finality before the rollout gates are live and during a health gate trip, so
    /// `onTicketRoute` covers that delivery whenever it can. A ticket that waits for an approver travels the receipt
    /// route, and its answer and first send come out of that window too: the approvers' answer time is not measured
    /// on chain, so `onReceiptRoute` is sized off chain to cover it.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - Both at most `LONGEST_VALIDITY_WINDOW` (one day); otherwise reverts with `ValidityWindowOutOfRange`. The
    ///   floors of the windows are sized off chain. A window of zero refuses every ask on that route.
    ///
    /// Emits `ValidityWindowsSet`.
    /// @param onTicketRoute The window, in seconds, of a ticket on the ticket route.
    /// @param onReceiptRoute The window, in seconds, of a ticket on the receipt route.
    function setValidityWindows(uint64 onTicketRoute, uint64 onReceiptRoute) external;

    /// @dev Sets the waiting time of the away chain `chainKey`: one waiting time after valid until anyone may ask for
    /// a ticket's receipt, and one more after an unanswered ask anyone may cancel it. Read at every send and cancel,
    /// so a change moves the asks and the cancel of tickets already out; `stopWaitingAt` stays the one of the ask.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - `duration` at least `MIN_WAITING_TIME`, one hour, and above the chain's full finality delivery plus clock
    ///   lead, so a second half arrives before its valid until; otherwise reverts with `WaitingTimeTooShort`. The
    ///   other conditions on a waiting time are sized off chain.
    ///
    /// Emits `WaitingTimeSet`.
    /// @param chainKey The chain, keyed as `MessageTypesLib.chainKey` computes it.
    /// @param duration The waiting time in seconds.
    function setWaitingTime(bytes32 chainKey, uint64 duration) external;

    /// @dev Sets the times measured for the away chain `chainKey`: the floor of its waiting time, the cap of a still
    /// open answer, and the shift a cancel on its closed route waits for. Set when the chain is added.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - The chain's waiting time, once set, still above the floor the new times give; otherwise reverts with
    ///   `WaitingTimeTooShort`.
    ///
    /// Emits `MeasuredTimesSet`.
    /// @param chainKey The away chain, keyed as `MessageTypesLib.chainKey` computes it.
    /// @param times The measured times, in seconds.
    function setMeasuredTimes(bytes32 chainKey, MeasuredTimes calldata times) external;

    /// @dev Pauses or resumes new asks that involve `chainKey`, as the sender's or the receiver's chain, or every new
    /// ask when `chainKey` is zero. Receipts, asks for receipts and cancels go on, so the tickets already out can end. Binding an approval
    /// module needs every ask paused.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    ///
    /// Emits `AsksPausedSet`.
    /// @param chainKey The away chain, keyed as `MessageTypesLib.chainKey` computes it, or zero for every chain.
    /// @param paused Whether new asks are refused.
    function setAsksPaused(bytes32 chainKey, bool paused) external;

    /// @dev Sets the limits on asks: how many tickets one identity may hold open, how many asks it may make per
    /// window, and the smallest amount one may ask to move. One identity can then use up only its own share of what
    /// home pays to send. A limit of zero refuses every ask.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - `limits.askWindow` must not be zero; otherwise reverts with `ZeroDuration`.
    ///
    /// Emits `AskLimitsSet`.
    /// @param limits The limits.
    function setAskLimits(AskLimits calldata limits) external;

    /// @dev Gives `identity` its own limit of asks per window, for an identity that moves often. Zero gives it the
    /// token's limit again.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    ///
    /// Emits `AskLimitOfSet`.
    /// @param identity The identity.
    /// @param asksPerWindow Its asks per window; zero for the token's limit.
    function setAskLimitOf(address identity, uint32 asksPerWindow) external;

    /// @dev Blocks the away chain `chainKey` on suspicion of fraud, before or after a bad receipt. While it is
    /// blocked no ticket goes to it, none of its tickets is cancelled, and every good receipt from it waits here,
    /// where `refuseWaitingReceipt` can delete one. The compliance also blocks a chain on its own when that chain
    /// sends a bad receipt or a receipt that breaks its terms. Blocking a blocked chain changes nothing.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    ///
    /// Emits `AwayChainBlockSet` with `true` when the chain was not blocked.
    /// @param chainKey The away chain, keyed as `MessageTypesLib.chainKey` computes it.
    function blockAwayChain(bytes32 chainKey) external;

    /// @dev Lifts the block of the away chain `chainKey`, once an investigation is over. Its waiting receipts are
    /// then applied by anyone, so a receipt a compromised bridge delivered is refused before. Unblocking a chain
    /// that is not blocked changes nothing.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    ///
    /// Emits `AwayChainBlockSet` with `false` when the chain was blocked.
    /// @param chainKey The away chain, keyed as `MessageTypesLib.chainKey` computes it.
    function unblockAwayChain(bytes32 chainKey) external;

    /// @dev Deletes the receipt waiting under `halfKey`, the named step for a receipt a compromised bridge
    /// delivered. Only while its away chain is blocked: unblocked, anyone may apply it, and the honest receipt for
    /// the half can still land afterwards.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - A receipt must wait under `halfKey`; otherwise reverts with `NoWaitingReceipt`.
    /// - Its away chain must be blocked; otherwise reverts with `AwayChainNotBlocked`.
    ///
    /// Emits `WaitingReceiptRefused`.
    /// @param halfKey The half the receipt waits under, see {MessageTypesLib-halfKeyOf}.
    function refuseWaitingReceipt(bytes32 halfKey) external;

    /// @dev Sets the caps on tickets toward the away chain `chainKey`. A receipt on older terms whose `seenMax` is
    /// above the per-ticket cap blocks that away chain. A change takes effect at once. An honest copy sent under a
    /// higher per-ticket cap would echo a `seenMax` above a lowered one and block an honest chain, so the operator
    /// lowers it only once every ticket sent under the old cap has expired. The per-window cap is read at each ask: a
    /// ticket that would take the ticket
    /// route above it in the current window of one waiting time travels the receipt route. The cap is shared by every
    /// holder: one identity can fill it, within its own ask limits, and the others then travel the receipt route,
    /// slower but never refused, until the window ends. A cap of zero sends every ticket toward the chain on the
    /// receipt route.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    ///
    /// Emits `TicketLimitsSet`.
    /// @param chainKey The away chain, keyed as `MessageTypesLib.chainKey` computes it.
    /// @param perTicketCap The most one ticket toward the chain may carry.
    /// @param perWindowCap The most the ticket route toward the chain may carry in one window of one waiting time.
    function setTicketLimits(bytes32 chainKey, uint256 perTicketCap, uint256 perWindowCap) external;

    /// @dev Cancels overdue tickets in a batch, for anyone: releases their reservations, so the next ask is computed as
    /// if they never happened. An open ticket is cancelled only once an ask for its receipt, sent at or after
    /// `waitingEndsAt` (the later of `validUntil` and `seenValidUntil`, plus the sender's chain's waiting time), has gone
    /// unanswered for one more waiting time: the away token answers an ask with its stored receipt, a zero receipt,
    /// or a still open answer, so an executed ticket is not cancelled over one lost or late message. A receipt that
    /// lands after the cancel is still applied as the move it is. The batch is atomic: one refused id reverts the
    /// whole call.
    ///
    /// Requirements:
    /// - Each id must have been issued; otherwise reverts with `UnknownTicket`.
    /// - A move `WaitingForApproval` may be cancelled by anyone once its `validUntil` passed, since nothing was sent
    ///   for it; otherwise reverts with `CancelNotDue`. So may a home `from`'s move the approver opened and nobody
    ///   sent: nothing leaves for it before its first send, which burns and sends the move out, and it never has an
    ///   ask. Of the rules below, only the token's stop, the block of its away chain, a hostile change, for an away
    ///   sender the open route of its away chain, and no receipt waiting that can be applied now
    ///   (`ApplyWaitingReceiptFirst`) apply to them: a copy from a dropped home block may be held there.
    /// - Each other id must be a move stored `Open`, sent or not; otherwise reverts with `TicketNotCancellable`. A
    ///   bring home is never cancelled: its half may still burn, and `sendSecondHalf` asks for its receipt.
    /// - An ask for its receipt sent at or after `waitingEndsAt`, and `block.timestamp` at least one waiting time past
    ///   that ask; otherwise reverts with `CancelNotDue`. A ticket from an away wallet the approver opened and nobody
    ///   sent has no ask until its first send, made at or after `waitingEndsAt`, counts as one.
    /// - The token not paused; otherwise reverts with `TokenPaused`: every receipt waits under the pause, so the
    ///   one that answers the ticket may be among them. This holds for a ticket `WaitingForApproval` too.
    /// - The sender's away chain not blocked; otherwise reverts with `AwayChainBlocked`: its receipts wait, and may
    ///   answer the ticket. This holds for a ticket `WaitingForApproval` too.
    /// - No hostile change running on the sender's away chain; otherwise reverts with `HostileChangeNotOver`: an
    ///   honest receipt still on the replaced pair may answer the ticket. This holds for a ticket `WaitingForApproval`
    ///   too.
    /// - The sender's away chain open on the token: a receipt route set, through a bridge still trusted at depth
    ///   zero; otherwise reverts with `ChainNotOpen`. Its receipt cannot land meanwhile, so it is not
    ///   taken as missing: once the route is closed, {closeByHand} decides it from a read of that chain.
    /// - No receipt for the ticket waiting that can be applied now; otherwise reverts with
    ///   `ApplyWaitingReceiptFirst`: the receipt is already here, and {applyWaitingReceipt} applies it first. A
    ///   waiting receipt that cannot be applied, because its route check fails or the sender's away balance is
    ///   below it, does not hold the cancel: it would lock the ticket open with no one able to apply it.
    ///
    /// Emits `TicketCancelled` per id.
    /// @param validationIds The tickets to cancel.
    function cancelTickets(bytes32[] calldata validationIds) external;

    /// @dev Sends a ticket, for anyone, on the route chosen at its ask. `to` is the one envelope the record does not
    /// keep; it is read off `TicketWaitingForApproval` or `TicketWritten`, like `spender`, and both must be the ones
    /// the ticket was asked with; otherwise reverts with `ValidationBodyMismatch`.
    ///
    /// The first send of a ticket the approver opened, toward the chain its first message goes to, read from the
    /// record: the sender's, or the receiver's for a home `from`. At any time: the token not paused and that chain
    /// open as at a request (`TokenPaused`, `AwayChainBlocked`, `HostileChangeNotOver`, `WaitingTimeNotSet`), and a
    /// receiver's other away chain not blocked (`AwayChainBlocked`): its route and peer were checked at the ask, and the
    /// ticket goes to the sender's chain; no receipt waiting for the ticket, otherwise `ApplyWaitingReceiptFirst`. Emits `TicketWritten`, as `askToMove`
    /// does with no approval module, and `ReceiptAsked` before it when sent at or after `waitingEndsAt`: that first
    /// send is also the first ask for the receipt. For a home `from`, burns onto hold and sends the `MOVE_OUT`
    /// instead; its maximum must still fit in the wallet's unfrozen balance, as at the ask, otherwise
    /// `RequestAboveBalance`.
    ///
    /// Otherwise a copy of an open ticket that left: sends the ticket again, byte for byte, through the bridge the
    /// first send pinned. Before `validUntil`, a resend of a lost ticket, which counts as no ask. At or after
    /// `waitingEndsAt` (the later of `validUntil` and `seenValidUntil`, plus the sender's chain's waiting time), an ask for the
    /// receipt, `MAX_RECEIPT_ASKS` at most: the away token answers a later copy with the receipt it stored, a zero
    /// receipt when the ticket expired unexecuted, or a still open answer. One send per waiting time either way. The
    /// copy goes to the sender's chain, read from the record.
    ///
    /// Requirements of a copy sent again:
    /// - `ticketId` must have been issued; otherwise reverts with `UnknownTicket`.
    /// - It must be a move stored `Open`; otherwise reverts with `ValidationNotResendable`. A bring home is sent
    ///   again with `sendSecondHalf`.
    /// - `block.timestamp` before `validUntil` or at or after `waitingEndsAt`, and at least one waiting time after the
    ///   last send; otherwise reverts with `SendNotDue`.
    /// - For an ask, fewer than `MAX_RECEIPT_ASKS` asks standing; otherwise reverts with `NoAsksLeft`.
    /// - The token must not be paused; otherwise reverts with `TokenPaused`.
    /// - The sender's chain must not be blocked; otherwise reverts with `AwayChainBlocked`.
    /// - No hostile change may run on the sender's chain; otherwise reverts with `HostileChangeNotOver`.
    /// - A receiver on another away chain: that chain not blocked; otherwise reverts with `AwayChainBlocked`. Its
    ///   route may have closed, or its peer been replaced as hostile, since the ask: the copy still goes to the
    ///   sender's chain, so an unanswered ask can still cancel the ticket.
    /// - `to` must have the recorded key and `spender` must be the recorded spender; otherwise reverts with
    ///   `ValidationBodyMismatch`.
    ///
    /// The ask goes to the pinned pair while it is the chain's current pair or its former pair inside the window of a
    /// planned change, and to the current pair otherwise.
    ///
    /// Emits `ReceiptAsked` for an ask, then the token's `ProtocolMessageSent`.
    /// @param ticketId The ticket sent again.
    /// @param to ERC-7930 interoperable address of the recipient, as issued.
    /// @param spender ERC-7930 address of the spender, as issued, or empty.
    function sendTicket(bytes32 ticketId, bytes calldata to, bytes calldata spender) external;

    /// @dev Sends the owed second half of a move, or sends its latest half again, for anyone. The money of the move is
    /// on hold at home, and the half mints it to `wallet` on its away chain: the receiver's wallet, or the sender's on
    /// a return. The half of an open bring home burns from `wallet` instead, and is sent again the same way.
    /// `wallet` is the one envelope the record does not keep; it is read off `SecondHalfSent`.
    ///
    /// An owed half, one that died answered zero after its valid until, is sent as a new half, with a fresh valid
    /// until: the send time plus the waiting time of its chain. At most `MAX_NEW_HALVES` halves per money on hold.
    /// A half whose send failed inside its receipt's delivery never left, and is sent under its own number. The halves
    /// of a cancel `cancelHold` started are sent here: an owed bring home on the receiver for what its uncounted credit
    /// covers, zero included, never while a later hold carries this one's credit (`LaterHoldStillCarries`), and the
    /// move out back to the sender.
    ///
    /// Otherwise the latest half is sent again, byte for byte, as an ask for its receipt: the away token answers with
    /// its stored receipt or a zero receipt. At most `MAX_SENDS_PER_HALF` sends per half, at fixed times: the second
    /// once the half's valid until plus one waiting time has passed, the third two waiting times after that, never
    /// counted from the last send. It goes only to the peer it was pinned to, which holds it: through the former pair
    /// inside the window of a planned change, or the current route while that peer is still the chain's. A new half is
    /// taken only after a zero answer or a failed send, never because the pair changed: the old half may still mint.
    ///
    /// Requirements:
    /// - `ticketId` must have been issued; otherwise reverts with `UnknownTicket`.
    /// - It must hold money on hold with a second half, or be an open bring home, and that half must be owed or have
    ///   sends left; otherwise reverts with `SecondHalfNotOwed`.
    /// - `wallet` must have the key of the half's wallet; otherwise reverts with `ValidationBodyMismatch`.
    /// - The token must not be paused, and `wallet`'s chain and the sender's chain not blocked; otherwise reverts
    ///   with `TokenPaused` or `AwayChainBlocked`. A hostile change does not stop a half: it goes to its pinned peer.
    /// - A send again only at or after its fixed time; otherwise reverts with `SendNotDue`.
    /// - A new half only below `MAX_NEW_HALVES`; otherwise reverts with `NoNewHalfLeft`.
    /// - A send again only to the half's pinned peer; otherwise the token reverts with `PeerChanged`.
    ///
    /// Emits `SecondHalfSent`, then the token's `HalfPinned` for a new half and `ProtocolMessageSent`. The halves
    /// taken so far are `ticketOf(ticketId).newHalves`.
    /// @param ticketId The ticket whose money is on hold.
    /// @param wallet ERC-7930 interoperable address of the wallet the half mints to.
    function sendSecondHalf(bytes32 ticketId, bytes calldata wallet) external;

    /// @dev Brings an away wallet's tokens home to a home wallet of the same identity: a move of place, never of owner.
    /// Writes an `Open` ticket of kind `BRING_HOME`, reserves `amount` on the away wallet in the same table as every
    /// ticket, and sends its half, a `BRING_HOME`, on the receipt route with its own valid until: now plus the waiting
    /// time of the wallet's chain. The away token burns what the wallet still holds, up to `amount`, and its receipt
    /// is applied as any receipt: what it burned is minted to `homeWallet` when that wallet is still linked to the
    /// identity and verified, and sent back to `awayWallet` by a `MOVE_OUT` otherwise; a zero answer ends the bring
    /// home `Done` with nothing moved. A lost half or receipt is asked for again with `sendSecondHalf`.
    ///
    /// The id is built from the request, as a move's is, under the kind `BRING_HOME`: the same request lands under
    /// the same id in any block, and a move and a bring home with the same wallets and salt never share one.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - `amount` not zero; otherwise reverts with `ZeroValue`.
    /// - `awayWallet` canonical and on another chain; otherwise `NonCanonicalInteroperableAddress` or
    ///   `NotASatelliteWallet`.
    /// - The token not paused, otherwise `TokenPaused`; the wallet's chain not blocked, otherwise `AwayChainBlocked`;
    ///   no hostile change running on it, otherwise `HostileChangeNotOver`; and a waiting time set for it, otherwise
    ///   `WaitingTimeNotSet`.
    /// - `homeWallet` and `awayWallet` linked to one existing identity; otherwise reverts with `WalletsNotLinked`.
    /// - No other bring home open on `awayWallet`; otherwise reverts with `BringHomeAlreadyOpen`.
    /// - `amount` at most the wallet's free balance, its away balance less what is reserved; otherwise reverts with
    ///   `RequestAboveBalance`.
    /// - The id not yet recorded; otherwise reverts with `TicketAlreadyWritten`.
    /// - The wallet's chain open on the token; otherwise the token reverts with `ChainNotOpen`.
    ///
    /// Emits `TicketWritten`, the token's `ReservedForValidation`, `SecondHalfSent`, then the token's `HalfPinned`
    /// and `ProtocolMessageSent`.
    /// @param awayWallet ERC-7930 interoperable address of the away wallet to burn from.
    /// @param amount The most the away token burns.
    /// @param homeWallet The home wallet to mint to.
    /// @param salt The agent's nonce for this bring home; with the rest of the request, it is the id.
    /// @return ticketId The id of the bring home's ticket.
    function bringHome(bytes calldata awayWallet, uint256 amount, address homeWallet, bytes32 salt)
        external
        returns (bytes32 ticketId);

    /// @dev Starts the cancel of money on hold with no ticket, for anyone, once nobody took it: a receipt home has no
    /// ticket for was booked on hold under its sender, see {IReceiptHandler-receiveReceipt}, and the same ask was not
    /// mined again before `stopWaitingAt`. The cancel's first half is then owed, and `sendSecondHalf` sends it with the
    /// wallet it goes to, since the record keeps no wallet's bytes. When the away token moved the tokens to a wallet on
    /// its own chain, that half is a `BRING_HOME` on the receiver for at most its uncounted credit; what it burns goes
    /// back to the sender by a `MOVE_OUT`, as uncounted credit for the part this hold carried from an earlier one. When
    /// the tokens left the away chain, it is a `MOVE_OUT` back to the sender. A bring home that burns less than it
    /// asked, zero included, is a short cancel: the rest stays on hold, announced, and is not sent again until carried
    /// credit comes back to the receiver; `sendSecondHalf` then sends it again. Money on hold whose credit a later hold
    /// carries is cancelled after that later one, last in, first out.
    ///
    /// Requirements:
    /// - `ticketId` must be recorded; otherwise reverts with `UnknownTicket`.
    /// - It must be money on hold with no ticket whose cancel has not started; otherwise reverts with
    ///   `TicketNotCancellable`.
    /// - The token not paused, the sender's away chain not blocked and no hostile change running on it; otherwise
    ///   reverts with `TokenPaused`, `AwayChainBlocked` or `HostileChangeNotOver`.
    /// - At or after `stopWaitingAt`; otherwise reverts with `CancelNotDue`.
    /// - No later hold carrying its credit; otherwise reverts with `LaterHoldStillCarries`.
    ///
    /// Emits nothing: the half's `SecondHalfSent` follows from `sendSecondHalf`.
    /// @param ticketId The id the money on hold is kept under.
    function cancelHold(bytes32 ticketId) external;

    /// @dev Closes by hand what waits on an away chain whose receipt route was closed with `closeReceiptRoute`, the
    /// only way there (a distrusted bridge is not): no receipt can land from it, and its silence cannot tell a dead
    /// chain from a lost message. So home decides from `reading`, the away chain's own state in one final block, never
    /// from home's clock.
    ///
    /// When the away token stored a receipt above zero for the half, it is applied as if it had arrived, see
    /// {IReceiptHandler-receiveReceipt}, and nothing is returned; a stored receipt for an id home has no record of is
    /// booked on hold. Otherwise, for:
    /// - an open move, or one waiting for approval: it is cancelled, whether its chain is blocked or not, once that
    ///   chain's clock is past the latest valid until its copies can carry: home's own plus the chain's reorg slot
    ///   shift, the one a still open answer reported, and the stored copy's. A cancel, so not while a hostile change
    ///   runs on that chain;
    /// - an open bring home: it ends `Done` with nothing moved once that chain's clock is past its half's valid until;
    /// - money on hold, its second half going to the receiver or back to the sender: once that chain's clock is past
    ///   the half's valid until, the money goes back to the sender by a new `MOVE_OUT` while the sender's chain has a
    ///   receipt route; otherwise it is minted at once to a home sender, or to the sender's identity contract;
    /// - money on hold with no ticket whose tokens left their chain, the closed one: the carried part of an earlier
    ///   hold is applied first, then the money is minted to the sender's identity contract, once its cancel is due
    ///   and that chain's clock is past the valid until of a return half that is out;
    /// - money on hold with no ticket, moved inside that chain: what the receiver still holds as uncounted credit is
    ///   applied as the move inside that chain it was, never minted to the sender, after the carried part of an
    ///   earlier hold is applied first. Last in, first out: never while a later hold carries this one's credit. Each
    ///   move counts for the identity its receiver has at the close, not the one read when the receipt was booked.
    ///   The rules are asked again about each move; one they refuse is announced with `MoveBreachedRule`, never
    ///   refused, since the away token already made it. Once its cancel's bring home burned some of it, and the move
    ///   out of that part back to the sender is past its valid until on that chain's clock, or never left: only what
    ///   burned is minted to the sender's identity contract, and the rest stays on hold, short.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - `ticketId` recorded, or a stored receipt above zero read for it; otherwise reverts with `UnknownTicket`.
    /// - The away chain of the latest half, or of the stored receipt's sender for an id with no record, has its
    ///   receipt route closed; otherwise reverts with `ReceiptRouteNotClosed`.
    /// - The token not paused; otherwise reverts with `TokenPaused`.
    /// - A stored receipt for `ticketId`, which home applies, with that chain not blocked; otherwise reverts with
    ///   `ValidationBodyMismatch` (a receipt home would refuse as bad, or keep waiting, is never taken from a read) or
    ///   `AwayChainBlocked`.
    /// With no stored receipt, the away chain's own clock decides; a receipt waiting at home on the closed route can
    /// never be applied, so it does not hold the close:
    /// - `receiver` with the key of the ticket's receiver; otherwise reverts with `ValidationBodyMismatch`.
    /// - One of the cases above; otherwise reverts with `TicketNotCancellable`.
    /// - For an open move or one waiting for approval, no hostile change running on its chain; otherwise reverts with
    ///   `HostileChangeNotOver`. For any other case, neither the half's chain nor the sender's chain blocked;
    ///   otherwise reverts with `AwayChainBlocked`.
    /// - `reading.awayClockTime` at or after the valid until the case needs; otherwise reverts with
    ///   `AwayClockBeforeValidUntil`.
    /// - For money on hold with no ticket: no later hold carrying it, otherwise `LaterHoldStillCarries`; and, before
    ///   its cancel started, `stopWaitingAt` passed, otherwise `CancelNotDue`; `receiver`, and the sender when its
    ///   hold carries an earlier one, linked to an identity now, otherwise `UnverifiedWallet`.
    ///
    /// Emits what the applied receipt, the cancel or the return emits, then `ClosedByHand`.
    /// @param ticketId The ticket, money on hold or id to close.
    /// @param receiver ERC-7930 interoperable address of the ticket's receiver, read off `TicketWritten` or
    /// `ReceiptWithoutTicket`; not read when a stored receipt is applied.
    /// @param reading What was read from the closed away chain.
    function closeByHand(bytes32 ticketId, bytes calldata receiver, AwayChainReading calldata reading) external;

    /// @dev The two validity windows, zero until set, which blocks issuance.
    function validityWindows() external view returns (ValidityWindows memory);

    /// @dev The times measured for `chainKey`, zero until set.
    /// @param chainKey The away chain to look up.
    function measuredTimesOf(bytes32 chainKey) external view returns (MeasuredTimes memory);

    /// @dev Whether new asks are paused for `chainKey`, or for every chain when it is zero.
    /// @param chainKey The away chain to look up, or zero for every chain.
    function areAsksPaused(bytes32 chainKey) external view returns (bool);

    /// @dev The limits on asks, zero until set, which blocks issuance.
    function askLimits() external view returns (AskLimits memory);

    /// @dev The asks per window `identity` may make: its own limit when it has one, the token's otherwise.
    /// @param identity The identity to look up.
    function askLimitOf(address identity) external view returns (uint32);

    /// @dev The waiting time configured for `chainKey`, zero when unset, which blocks issuance.
    /// @param chainKey The chain to look up.
    function waitingTimeOf(bytes32 chainKey) external view returns (uint64);

    /// @dev Whether the away chain `chainKey` is blocked, see `blockAwayChain`.
    /// @param chainKey The away chain to look up.
    function isAwayChainBlocked(bytes32 chainKey) external view returns (bool);

    /// @dev The caps on tickets toward `chainKey`, zero until set.
    /// @param chainKey The away chain to look up.
    function ticketLimitsOf(bytes32 chainKey) external view returns (TicketLimits memory);

    /// @dev Applies the receipt waiting under `halfKey`, as it would have been applied at delivery, see
    /// {IReceiptHandler-receiveReceipt}: `WaitingReceiptApplied` is emitted, and the away chain is blocked when the
    /// receipt breaks its terms. Anyone may call it once the receipt can be applied. The route check runs again on
    /// the bridge and peer that delivered it, so a bridge distrusted, a route closed or a peer replaced meanwhile
    /// refuses it. The receipt is judged again first, against the record as it is now, as a delivery is: a ticket
    /// written since it arrived makes a receipt that names other wallets a bad receipt, refused, deleted and blocking
    /// its chain. A receipt that reverts here, a tracker module that refuses it for instance, stays waiting.
    ///
    /// Requirements:
    /// - `receipt` must be the one waiting under `halfKey`; otherwise reverts with `NoWaitingReceipt`.
    /// - For the ticket's own half, its ticket must be sent; otherwise reverts with `NoWaitingReceipt`.
    /// - The token must not be paused; otherwise reverts with `TokenPaused`.
    /// - Its away chain must not be blocked; otherwise reverts with `AwayChainBlocked`.
    /// - For the ticket's own half, or a bring home's burn receipt, the sender's away balance must cover the amount;
    ///   otherwise reverts with `InsufficientBridgedBalance`. Any other half's money is already on hold at home.
    /// - The route check of {ITREXMessaging-checkReceiptOrigin} must pass; otherwise the token reverts with its
    ///   error.
    ///
    /// Emits `WaitingReceiptApplied`, and `AwayChainBlockSet` on broken terms; or `ReceiptRefused` and
    /// `AwayChainBlockSet` for a receipt judged bad now.
    /// @param halfKey The half the receipt waits under, see {MessageTypesLib-halfKeyOf}.
    /// @param receipt The receipt, as `ReceiptWaiting` carried it.
    function applyWaitingReceipt(bytes32 halfKey, MessageTypesLib.ReceiptMessage calldata receipt) external;

    /// @dev The receipt waiting under `halfKey`, `bodyHash` zero when none waits.
    /// @param halfKey The half to look up, see {MessageTypesLib-halfKeyOf}.
    function waitingReceiptOf(bytes32 halfKey) external view returns (WaitingReceipt memory);

    /// @dev Everything kept for `ticketId`, all zeros when the id was never issued.
    /// @param ticketId The ticket to look up.
    function ticketOf(bytes32 ticketId) external view returns (Ticket memory);

    /// @dev Where `ticketId` stands.
    ///
    /// Requirements:
    /// - `ticketId` must have been taken; otherwise reverts with `UnknownTicket`.
    /// @param ticketId The ticket to look up.
    function statusOf(bytes32 ticketId) external view returns (TicketStatus);

}
