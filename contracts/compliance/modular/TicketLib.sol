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
import { ITrustedGatewayRegistry } from "../../interop/ITrustedGatewayRegistry.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { MessageTypesLib } from "../../libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "../../libraries/WalletKeyLib.sol";
import { ITREXRegistry } from "../../registry/interface/ITREXRegistry.sol";
import { IToken } from "../../token/IToken.sol";
import { ComplianceLedgerLib } from "./ComplianceLedgerLib.sol";
import { HoldLib } from "./HoldLib.sol";
import { ITickets } from "./ITickets.sol";
import { ModuleSetLib } from "./ModuleSetLib.sol";
import { SecondHalfLib } from "./SecondHalfLib.sol";
import { TransferContextLib } from "./TransferContextLib.sol";
import { IApprovalModule } from "./modules/IApprovalModule.sol";
import { IModule } from "./modules/IModule.sol";

/**
 * @title TicketLib
 * @dev The layout of the compliance's ticket record, and the first part of a ticket's life, deployed once and
 * linked: the questions a request must answer, then the id built from the whole request,
 * the record, the reservation, the announcement and the ticket the away token will execute against; the
 * answer of an approval; the ask for the receipt; and the table of what each ticket state keeps reserved, {moveTo}.
 *
 * That is storage writes and ABI encoding the compliance would otherwise carry, and it is what kept it over
 * EIP-170. The compliance reaches it by DELEGATECALL, so the storage is its own namespaces at the slots they
 * always had, the token and the modules see the compliance as their caller, and every event is the
 * compliance's. What happens once an away token executed, or never did, is {ReceiptLib}.
 */
library TicketLib {

    using EnumerableSet for EnumerableSet.AddressSet;

    /// @custom:storage-location erc7201:erc3643.storage.TransferValidation
    struct ValidationStorage {
        /// Added to the ask's timestamp to compute `validUntil`, per the route the ticket travels. Zero blocks asks.
        ITickets.ValidityWindows validityWindows;
        /// The waiting time of each away chain. Zero blocks asks from that chain.
        mapping(bytes32 chainKey => uint64 window) waitingTimes;
        /// Every ticket, kept forever, under its id, see {ticketIdOf}.
        mapping(bytes32 ticketId => ITickets.Ticket validation) validations;
        /// Good receipts that could not be applied yet, per half, see {ITickets-WaitingReceipt}. Written by the
        /// receipt path, deleted when applied or refused by hand.
        mapping(bytes32 halfKey => ITickets.WaitingReceipt receipt) waitingReceipts;
        /// The receipt home applied for each half, as `keccak256(abi.encode(chainKey, receipt))`, see
        /// {MessageTypesLib-halfKeyOf}. The same receipt again changes nothing; another one is a bad receipt.
        mapping(bytes32 halfKey => bytes32 receiptHash) receiptHashes;
        /// The caps on tickets toward each away chain.
        mapping(bytes32 chainKey => ITickets.TicketLimits limits) ticketLimits;
        /// Away chains blocked by the pauser or by a bad receipt: no ticket goes to them, none of their tickets is
        /// cancelled, and their receipts wait.
        mapping(bytes32 chainKey => bool blocked) blockedAwayChains;
        /// The times measured for each away chain: the floor of its waiting time, the cap of a still open answer and
        /// the shift a closed-route cancel waits for.
        mapping(bytes32 chainKey => ITickets.MeasuredTimes times) measuredTimes;
        /// The latest `stopWaitingAt` of any ticket: the compliance is not unbound before it.
        uint64 latestStopWaitingAt;
        /// New asks refused for every chain.
        bool asksPaused;
        /// The limits on asks, see {ITickets-setAskLimits}.
        ITickets.AskLimits askLimits;
        /// The asks per window of an identity that has its own limit; zero for the token's limit.
        mapping(address identity => uint32 asksPerWindow) askLimitOverrides;
        /// What each identity asked: its open tickets and its asks in the current window.
        mapping(address identity => IdentityAsks asks) identityAsks;
        /// The bring home open on each away wallet, zero when none: one at a time per wallet.
        mapping(bytes32 walletKey => bytes32 ticketId) openBringHome;
        /// The latest money on hold that gave the wallet uncounted credit: a receipt with no ticket that spends that
        /// credit carries it from there.
        mapping(bytes32 walletKey => bytes32 ticketId) uncountedCreditFrom;
        /// What the ticket route toward each away chain carried in its current window of one waiting time, held
        /// under the chain's per-window cap, see {ITickets-TicketLimits}.
        mapping(bytes32 chainKey => TicketRouteVolume volume) ticketRouteVolumes;
        /// New asks refused for one away chain: the chain the first message of the ask goes to.
        mapping(bytes32 chainKey => bool paused) asksPausedOn;
    }

    /// @dev What the ticket route toward one away chain carried in its current window.
    struct TicketRouteVolume {
        /// When the current window started.
        uint64 windowStart;
        /// The sum of the `amountMax` of the tickets it carried since then.
        uint256 amount;
    }

    /// @dev What one identity asked, counted against {ITickets-AskLimits}.
    struct IdentityAsks {
        /// Its tickets waiting for approval or open.
        uint32 openTickets;
        /// Its asks since `windowStartedAt`.
        uint32 asksInWindow;
        /// When its current window of asks started.
        uint64 windowStartedAt;
    }

    /// @dev The most asks for the receipt of one ticket.
    uint8 internal constant MAX_RECEIPT_ASKS = 3;

    /// @dev The shortest waiting time any away chain may have, in seconds.
    uint64 internal constant MIN_WAITING_TIME = 1 hours;

    /// @dev The longest validity window, in seconds: how old the rules may be when an away token executes a ticket,
    ///  OpenZeppelin's staleness the product accepts (V_stale). OpenZeppelin gives no number: one day until the
    ///  owner gives it.
    uint64 internal constant LONGEST_VALIDITY_WINDOW = 1 days;

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.TransferValidation")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant VALIDATION_STORAGE_LOCATION =
        0x518dcda4927033bd42da8dd6047b92b4a950cebbc5bdd8461a5e9bb9c0545400;

    /// @dev What issuance works out before the first write, in memory so the flow stays one function.
    struct Draft {
        /// The sender as a home wallet; zero for an away sender.
        address homeWallet;
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
        /// The ask block hash, see {askBlockHashOf}, written by {_record}.
        bytes32 askBlockHash;
        /// An `APPROVAL` module is bound: the ticket waits for its answer.
        bool waitedForApproval;
        /// The route the ticket travels, see {_chooseTheRoute}.
        bool onReceiptRoute;
    }

    /// @dev Writes a ticket, see {ITickets-askToMove}. Where is this going and may the caller ask for it; then the
    ///  id of the request, and the take of money on hold a receipt for that id put there first, before any question
    ///  on limits or balances: those tokens already left the sender's wallet, so asking for them again would refuse
    ///  the ask. Then by when must it happen, how much may actually move, and may the named spender execute it.
    ///  Only then is anything written.
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
        require(!layout().asksPaused, ErrorsLib.AsksPaused());
        require(requestedMin <= requestedMax, ErrorsLib.InvalidRequestedRange(requestedMin, requestedMax));

        Draft memory draft;
        draft.amountMin = requestedMin;
        draft.amountMax = requestedMax;
        draft.requestedMax = requestedMax;
        _resolveRoute(draft, from, to, spender);
        require(!layout().asksPausedOn[_firstChainOf(draft)], ErrorsLib.AsksPaused());
        _requireCallerOwnsTheWallet(draft, from, token, authority);

        ticketId = ticketIdOf(
            ITickets.TicketKind.MOVE,
            draft.fromKey,
            draft.toKey,
            spenderKeyOf(spender),
            draft.amountMin,
            draft.requestedMax,
            salt
        );
        if (_mayTakeTheHold(ticketId)) {
            _takeTheHold(ticketId, from, to, spender, salt, draft, token);
            return ticketId;
        }
        require(!isRecorded(layout(), ticketId), ErrorsLib.TicketAlreadyWritten(ticketId));

        _requireWithinAskLimits(draft);
        draft.waitingTime = _openTheFirstChain(token, _firstChainOf(draft));
        _requireTheReceiversChainOpen(token, _firstChainOf(draft), to);
        _narrowAmountRange(draft, from, to, spender, token);
        _requireSpenderAllowed(draft, to, spender);
        _chooseTheRoute(draft, token);

        // Issued and sent at once, or kept awaiting approval while an `APPROVAL` module is bound.
        _issue(ticketId, from, to, spender, salt, draft, token);
    }

    /// @dev The ask takes the money on hold under its id, see {HoldLib-take}, with the range it asked for. In its own
    ///  call frame: {request} has no stack room left for the call.
    function _takeTheHold(
        bytes32 ticketId,
        bytes calldata from,
        bytes calldata to,
        bytes calldata spender,
        bytes32 salt,
        Draft memory draft,
        address token
    ) private {
        HoldLib.take(ticketId, from, to, spender, draft.amountMin, draft.requestedMax, salt, token);
    }

    /// @dev Whether the ask may take the money on hold under its id: a record a receipt created, still on hold with no
    ///  destination and no cancel started, while no approval module is bound, since an approver never saw that move.
    function _mayTakeTheHold(bytes32 ticketId) private view returns (bool) {
        ITickets.Ticket storage ticket = layout().validations[ticketId];
        bool noApprovalModule = _approvalModule() == address(0);
        return HoldLib.isATakeableHold(ticket) && noApprovalModule;
    }

    /// @dev The route the ticket travels, chosen once here and written on it: every later send reads the ticket,
    ///  never the settings of the day. The receipt route, at full finality, for a ticket that waits for an approver
    ///  (a reorg short of finality could drop the answer after the away token acted), a home wallet's move out, a
    ///  chain with no trusted ticket bridge, a ticket above the chain's per-ticket cap, or one that would take the
    ///  ticket route above its per-window cap: the caps bound what a dropped home block can cost. Then the deadline
    ///  from that route's validity window: a ticket at full finality takes longer to arrive.
    function _chooseTheRoute(Draft memory draft, address token) private view {
        draft.waitedForApproval = _approvalModule() != address(0);
        draft.onReceiptRoute = _travelsOnTheReceiptRoute(draft, token);

        ITickets.ValidityWindows memory windows = layout().validityWindows;
        uint64 validityWindow = windows.onTicketRoute;
        if (draft.onReceiptRoute) validityWindow = windows.onReceiptRoute;
        require(validityWindow != 0, ErrorsLib.ValidityWindowNotSet());
        draft.validUntil = uint64(block.timestamp) + validityWindow;
    }

    /// @dev Whether the ticket must travel the receipt route, see {_chooseTheRoute}.
    function _travelsOnTheReceiptRoute(Draft memory draft, address token) private view returns (bool) {
        bool aHomeWalletMovesOut = draft.homeWallet != address(0);
        if (draft.waitedForApproval || aHomeWalletMovesOut) return true;
        if (!_hasATrustedTicketBridge(token, draft.fromChainKey)) return true;

        ValidationStorage storage store = layout();
        ITickets.TicketLimits memory limits = store.ticketLimits[draft.fromChainKey];
        bool aboveThePerTicketCap = draft.amountMax > limits.perTicketCap;
        uint256 carriedInTheWindow = _carriedInTheCurrentWindow(store, draft.fromChainKey, draft.waitingTime);
        bool aboveThePerWindowCap = carriedInTheWindow + draft.amountMax > limits.perWindowCap;
        return aboveThePerTicketCap || aboveThePerWindowCap;
    }

    /// @dev Whether the token sends tickets toward `chainKey` on a ticket bridge the registry still trusts.
    function _hasATrustedTicketBridge(address token, bytes32 chainKey) private view returns (bool) {
        ITREXMessaging messaging = ITREXMessaging(token);
        address ticketRoute = messaging.ticketRouteFor(chainKey);
        if (ticketRoute == address(0)) return false;
        return ITrustedGatewayRegistry(messaging.trustedGatewayRegistry()).isTrusted(ticketRoute);
    }

    /// @dev What the ticket route toward `chainKey` carried in its current window of one waiting time; zero once
    ///  that window is over.
    function _carriedInTheCurrentWindow(ValidationStorage storage store, bytes32 chainKey, uint64 waitingTime)
        private
        view
        returns (uint256)
    {
        TicketRouteVolume storage volume = store.ticketRouteVolumes[chainKey];
        bool windowOver = block.timestamp >= volume.windowStart + waitingTime;
        if (windowOver) return 0;
        return volume.amount;
    }

    /// @dev Counts a ticket on the ticket route toward its chain: in the current window, or in a new one from now
    ///  once the last one is over.
    function _countOnTheTicketRoute(ValidationStorage storage store, Draft memory draft) private {
        uint256 carriedSoFar = _carriedInTheCurrentWindow(store, draft.fromChainKey, draft.waitingTime);
        TicketRouteVolume storage volume = store.ticketRouteVolumes[draft.fromChainKey];
        if (carriedSoFar == 0) volume.windowStart = uint64(block.timestamp);
        volume.amount = carriedSoFar + draft.amountMax;
    }

    /// @dev Where the move goes: both envelopes parse, and at most one of the two wallets is a home wallet. A move
    ///  that leaves its away chain is done in two halves, home sending the second one once the first is done; a
    ///  home wallet's move out has the second half only. A home sender names no spender: it moves its own tokens in
    ///  the ask itself. The spender is parsed here and judged in {_requireSpenderAllowed}, once the range is known.
    function _resolveRoute(Draft memory draft, bytes calldata from, bytes calldata to, bytes calldata spender)
        private
        view
    {
        (bool fromHome, address homeWallet) = WalletKeyLib.isReferenceChain(from);
        (bool toHome,) = WalletKeyLib.isReferenceChain(to);
        bool bothAtHome = fromHome && toHome;
        require(!bothAtHome, ErrorsLib.NotACrossChainMove());
        draft.homeWallet = homeWallet;
        draft.fromChainKey = _chainKeyOf(from);
        draft.toChainKey = _chainKeyOf(to);
        draft.fromKey = WalletKeyLib.canonicalKey(from);
        draft.toKey = WalletKeyLib.canonicalKey(to);
        if (spender.length == 0) return;
        require(!fromHome, ErrorsLib.ValidationSpenderRefused(spender));
        WalletKeyLib.parse(spender);
    }

    /// @dev The chain the move's first message goes to: the sender's away chain for its ticket, or the receiver's
    ///  for a home wallet's move out. Its waiting time, its block and its validity window rule the ask.
    function _firstChainOf(Draft memory draft) private pure returns (bytes32) {
        bool fromHome = draft.homeWallet != address(0);
        if (fromHome) return draft.toChainKey;
        return draft.fromChainKey;
    }

    /// @dev The limits on asks, see {ITickets-setAskLimits}: the sender's identity below its open tickets and its asks
    ///  in the current window, and the asked maximum not below the smallest amount. Counted per identity, never
    ///  under a quota other holders share, so one identity can use up only its own asks.
    function _requireWithinAskLimits(Draft memory draft) private view {
        ValidationStorage storage store = layout();
        ITickets.AskLimits memory limits = store.askLimits;
        IdentityAsks memory asks = store.identityAsks[draft.fromIdentity];
        require(asks.openTickets < limits.openTicketsPerIdentity, ErrorsLib.TooManyOpenTickets(draft.fromIdentity));
        uint32 asksSoFar = _asksInTheCurrentWindow(asks, limits.askWindow);
        require(asksSoFar < askLimitOf(store, draft.fromIdentity), ErrorsLib.AskLimitReached(draft.fromIdentity));
        require(
            draft.requestedMax >= limits.smallestAmount,
            ErrorsLib.BelowMinimumAmount(draft.requestedMax, limits.smallestAmount)
        );
    }

    /// @dev The asks an identity made in its current window; zero once the window is over.
    function _asksInTheCurrentWindow(IdentityAsks memory asks, uint64 askWindow) private view returns (uint32) {
        bool windowOver = block.timestamp >= asks.windowStartedAt + askWindow;
        if (windowOver) return 0;
        return asks.asksInWindow;
    }

    /// @dev Counts an ask against its identity: one more open ticket, one more ask in the window, a new window once
    ///  the last one is over.
    function _countTheAsk(ValidationStorage storage store, address identity) private {
        IdentityAsks storage asks = store.identityAsks[identity];
        uint32 asksSoFar = _asksInTheCurrentWindow(asks, store.askLimits.askWindow);
        if (asksSoFar == 0) asks.windowStartedAt = uint64(block.timestamp);
        asks.asksInWindow = asksSoFar + 1;
        asks.openTickets += 1;
    }

    /// @dev The asks per window `identity` may make: its own limit when it has one, the token's otherwise.
    function askLimitOf(ValidationStorage storage store, address identity) internal view returns (uint32) {
        uint32 ownLimit = store.askLimitOverrides[identity];
        if (ownLimit != 0) return ownLimit;
        return store.askLimits.asksPerIdentityPerWindow;
    }

    /// @dev Who may ask: for an away wallet, the identity it is linked to, since that wallet has no address here; for a
    ///  home wallet, the wallet itself, never its identity; or an address the AccessManager authorised for this
    ///  selector.
    function _requireCallerOwnsTheWallet(Draft memory draft, bytes calldata from, address token, address authority)
        private
        view
    {
        draft.fromIdentity = address(_registryOf(token).resolveIdentity(from));
        require(draft.fromIdentity != address(0), ErrorsLib.UnverifiedWallet(from));
        bool anAwayWallet = draft.homeWallet == address(0);
        bool callerIsTheWalletsIdentity = anAwayWallet && msg.sender == draft.fromIdentity;
        bool callerIsTheHomeWallet = msg.sender == draft.homeWallet;
        bool callerOwnsTheWallet = callerIsTheWalletsIdentity || callerIsTheHomeWallet;
        require(
            callerOwnsTheWallet || _mayRequestForAnyWallet(authority),
            ErrorsLib.NotAuthorizedForWallet(msg.sender, from)
        );
    }

    /// @dev Whether the AccessManager lets the caller ask for any wallet, now. Asked only when
    ///  the caller is not the wallet's identity, so an identity pays no call to the manager.
    function _mayRequestForAnyWallet(address authority) private view returns (bool) {
        (bool immediate,) =
            AuthorityUtils.canCallWithDelay(authority, msg.sender, address(this), ITickets.askToMove.selector);
        return immediate;
    }

    /// @dev How much may move. The asked maximum must fit in what the sending wallet has free; the range then only
    ///  ever narrows, to the smallest amount the rules allow.
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

        _requireRequestWithinTheFreeBalance(draft, from, token);
        _capAtWhatTheRulesAllow(draft, to, spender);
        require(draft.amountMax != 0, ErrorsLib.ZeroValue());
    }

    /// @dev The asked maximum must fit in what the sending wallet can still send: an away wallet's balance less what
    ///  earlier tickets may still draw from it, an open bring home included, or a home wallet's unfrozen balance.
    ///  Refused, not narrowed: the id is built from the asked maximum, so a ticket narrowed here would carry a maximum
    ///  its id does not name.
    function _requireRequestWithinTheFreeBalance(Draft memory draft, bytes calldata from, address token) private view {
        uint256 free;
        if (draft.homeWallet != address(0)) {
            free = IToken(token).freeBalanceOf(draft.homeWallet);
        } else {
            free = IToken(token).availableOf(from);
        }
        require(draft.requestedMax <= free, ErrorsLib.RequestAboveBalance(from, free, draft.requestedMax));
    }

    /// @dev Caps the range at the smallest amount the rules allow. Skipped when both wallets belong to one
    ///  identity, since relocating your own tokens changes no position and no distribution rule applies.
    function _capAtWhatTheRulesAllow(Draft memory draft, bytes calldata to, bytes calldata spender) private view {
        if (ComplianceLedgerLib.isRelocation(draft.fromIdentity, draft.toIdentity)) return;
        IModule.TransferContext memory transferContext = TransferContextLib.issuance(
            draft.fromChainKey,
            draft.fromIdentity,
            draft.toIdentity,
            draft.fromKey,
            WalletKeyLib.walletId(to),
            draft.amountMin,
            draft.amountMax,
            spender
        );
        uint256 allowed = ModuleSetLib.callCheckTransfer(transferContext);
        if (allowed < draft.amountMax) draft.amountMax = allowed;
        require(draft.amountMin <= draft.amountMax, ErrorsLib.EmptyValidationRange(draft.amountMin, draft.amountMax));
    }

    /// @dev Who may execute: every `SPENDER` module must accept the named spender, since no module runs on the
    ///  away chain and this is the only place it can be refused. A ticket the sender executes itself names
    ///  no spender and asks nobody. Asked on a relocation too: who executes is not about distribution.
    function _requireSpenderAllowed(Draft memory draft, bytes calldata to, bytes calldata spender) private view {
        if (spender.length == 0) return;
        IModule.TransferContext memory transferContext = TransferContextLib.issuance(
            draft.fromChainKey,
            draft.fromIdentity,
            draft.toIdentity,
            draft.fromKey,
            WalletKeyLib.walletId(to),
            draft.amountMin,
            draft.amountMax,
            spender
        );
        require(ModuleSetLib.spenderAllowed(transferContext), ErrorsLib.ValidationSpenderRefused(spender));
    }

    /// @dev Turns a finished draft into a ticket under its id: keep its terms and reserve the amount. With no
    ///  `APPROVAL` module bound, issue it at once: build the object the away token will execute against, announce it
    ///  and send it to the sender's away chain on the route chosen at the ask. With one bound, keep it
    ///  `WaitingForApproval` instead, sent nowhere until {answerApproval} opens it and anyone sends it, see {sendTicket}.
    /// @param ticketId the id of the whole request, see {ticketIdOf}
    /// @param salt the requester's nonce, see {ITickets-askToMove}
    /// @param token the token the compliance is bound to
    function _issue(
        bytes32 ticketId,
        bytes calldata from,
        bytes calldata to,
        bytes calldata spender,
        bytes32 salt,
        Draft memory draft,
        address token
    ) private {
        _record(ticketId, from, spender, draft, token);
        layout().validations[ticketId].salt = salt;

        address approvalModule = _approvalModule();
        if (approvalModule != address(0)) {
            _awaitApproval(ticketId, from, to, spender, draft, approvalModule);
            return;
        }
        if (draft.homeWallet != address(0)) {
            SecondHalfLib.moveOutFromHome(ticketId, to, token);
            return;
        }

        bytes memory body = _issueRecorded(
            ticketId,
            MessageTypesLib.TicketMessage({
                ticketId: ticketId,
                kind: uint8(ITickets.TicketKind.MOVE),
                salt: salt,
                from: from,
                to: to,
                spender: spender,
                amountMin: draft.amountMin,
                amountMax: draft.amountMax,
                requestedMax: draft.requestedMax,
                token: token,
                validUntil: draft.validUntil,
                askBlockHash: draft.askBlockHash
            })
        );
        _dispatch(token, ticketId, draft.fromChainKey, body);
    }

    /// @dev Answers a ticket awaiting approval, see {ITickets-answerApproval}. No rule runs again: every rule
    ///  ran and the range was reserved at the request, so an approval only narrows and opens the ticket. Nothing is
    ///  sent here: anyone makes the first send with {sendTicket}, so the approver never pays for a send, nor reverts
    ///  on a stopped token or a blocked chain.
    /// @param token the token the compliance is bound to
    function answerApproval(bytes32 ticketId, uint256 approvedMax, address token) external {
        ValidationStorage storage store = layout();
        require(isRecorded(store, ticketId), ErrorsLib.UnknownTicket(ticketId));
        ITickets.Ticket storage ticket = store.validations[ticketId];
        require(
            ticket.status == ITickets.TicketStatus.WaitingForApproval,
            ErrorsLib.NotWaitingForApproval(ticketId, uint8(ticket.status))
        );
        require(msg.sender == _approvalModule(), ErrorsLib.NotTheApprovalModule(msg.sender));
        require(block.timestamp < ticket.validUntil, ErrorsLib.ValidationExpired(ticketId, ticket.validUntil));
        bool refused = approvedMax == 0;
        bool insideTheRange = approvedMax >= ticket.amountMin && approvedMax <= ticket.amountMax;
        require(refused || insideTheRange, ErrorsLib.EmptyValidationRange(ticket.amountMin, ticket.amountMax));

        if (refused) {
            moveTo(ticket, ITickets.TicketStatus.Cancelled, token);
            emit EventsLib.ValidationApprovalRefused(ticketId);
            return;
        }

        // The deadline stays the request's: the rules ran then, so the time spent waiting comes out of the
        // away token's time to execute rather than adding to how old the rules may be when it does. Both rows hold
        // the ask, so the narrowing alone gives something back.
        if (approvedMax < ticket.amountMax) {
            _release(ticket, ticket.amountMax - approvedMax, token);
            ticket.amountMax = approvedMax;
        }
        ticket.status = ITickets.TicketStatus.Open;
    }

    /// @dev Sends a ticket, for anyone, see {ITickets-sendTicket}: the first send of a ticket the approver opened,
    ///  or a copy of a ticket that left. Either way the caller supplies the two envelopes again, which must be the
    ///  ones it was asked with, and the ticket travels the route chosen at its ask.
    /// @param token the token the compliance is bound to
    function sendTicket(bytes32 ticketId, bytes calldata to, bytes calldata spender, address token) external {
        ValidationStorage storage store = layout();
        require(isRecorded(store, ticketId), ErrorsLib.UnknownTicket(ticketId));
        ITickets.Ticket storage ticket = store.validations[ticketId];
        _requireTheAskedEnvelopes(ticket, ticketId, to, spender);
        bool approvedAndNotSent = ticket.status == ITickets.TicketStatus.Open && neverSent(ticket);
        if (approvedAndNotSent) {
            _sendTheApprovedTicket(store, ticket, ticketId, to, token);
            return;
        }
        _sendAgain(ticket, ticketId, to, spender, token);
    }

    /// @dev The first send of a ticket the approver opened, at any time, toward the chain its first message goes to,
    ///  which must be open as at a request. Sent at or after {waitingEndsAtOf}, it is also the first ask for the
    ///  receipt, so the ticket is cancelled only once that ask went unanswered. No receipt may wait for it: one that
    ///  came before the send answers no copy home sent, and is booked on hold once it can be. A home wallet's move out
    ///  is burned onto hold and sent instead, as at a request with no approval module.
    function _sendTheApprovedTicket(
        ValidationStorage storage store,
        ITickets.Ticket storage ticket,
        bytes32 ticketId,
        bytes calldata to,
        address token
    ) private {
        (bool fromHome,) = WalletKeyLib.isReferenceChain(ticket.fromWallet);
        bytes32 chainKey = ticket.fromChainKey;
        if (fromHome) chainKey = ticket.toChainKey;
        requireTokenRunning(token);
        _openChainWindow(store, token, chainKey);
        _requireTheReceiversChainOpen(token, chainKey, to);
        _requireNoReceiptWaitsForTheTicket(store, ticketId);

        if (fromHome) {
            SecondHalfLib.moveOutFromHome(ticketId, to, token);
            return;
        }
        bool anAsk = block.timestamp >= waitingEndsAtOf(ticket);
        if (anAsk) {
            ticket.asksForReceipt = 1;
            emit EventsLib.ReceiptAsked(ticketId, 1);
        }
        bytes memory body = _issueRecorded(
            ticketId,
            MessageTypesLib.TicketMessage({
                ticketId: ticketId,
                kind: uint8(ticket.kind),
                salt: ticket.salt,
                from: ticket.fromWallet,
                to: to,
                spender: ticket.spender,
                amountMin: ticket.amountMin,
                amountMax: ticket.amountMax,
                requestedMax: ticket.requestedMax,
                token: token,
                validUntil: ticket.validUntil,
                askBlockHash: ticket.askBlockHash
            })
        );
        _dispatch(token, ticketId, chainKey, body);
    }

    /// @dev Sends a ticket that left again: the ticket rebuilt from its record and the two envelopes, byte for byte,
    ///  ask block hash included. Before its valid until, a resend of a lost ticket, counted as no ask; from
    ///  {waitingEndsAtOf}, an ask for the receipt, at most `MAX_RECEIPT_ASKS` times; one send per waiting time either
    ///  way, see {_requireCanBeSentAgain}. A blocked sender's chain refuses it as it refuses an ask to move, and so do
    ///  a hostile change running on it, see {requireNoHostileChange}, and the token's own pause, see
    ///  {requireTokenRunning}.
    function _sendAgain(
        ITickets.Ticket storage ticket,
        bytes32 ticketId,
        bytes calldata to,
        bytes calldata spender,
        address token
    ) private {
        bytes32 chainKey = ticket.fromChainKey;
        bool anAsk = _requireCanBeSentAgain(ticket, ticketId);
        requireTokenRunning(token);
        requireAwayChainNotBlocked(chainKey);
        requireNoHostileChange(token, chainKey);
        _requireTheReceiversChainOpen(token, chainKey, to);

        MessageTypesLib.TicketMessage memory rebuilt = MessageTypesLib.TicketMessage({
            ticketId: ticketId,
            kind: uint8(ticket.kind),
            salt: ticket.salt,
            from: ticket.fromWallet,
            to: to,
            spender: spender,
            amountMin: ticket.amountMin,
            amountMax: ticket.amountMax,
            requestedMax: ticket.requestedMax,
            token: token,
            validUntil: ticket.validUntil,
            askBlockHash: ticket.askBlockHash
        });

        if (anAsk) {
            ticket.asksForReceipt += 1;
            emit EventsLib.ReceiptAsked(ticketId, ticket.asksForReceipt);
        }
        ticket.lastSentAt = uint64(block.timestamp);

        _sendOnItsRoute(token, ticket.onReceiptRoute, ticketId, chainKey, abi.encode(rebuilt));
    }

    /// @dev The envelopes a caller gives back for a ticket must be the ones it was asked with: the receiver's has the
    ///  recorded key, the spender is the recorded one.
    function _requireTheAskedEnvelopes(
        ITickets.Ticket storage ticket,
        bytes32 ticketId,
        bytes calldata to,
        bytes calldata spender
    ) private view {
        require(WalletKeyLib.canonicalKey(to) == ticket.toKey, ErrorsLib.ValidationBodyMismatch(ticketId));
        require(keccak256(spender) == keccak256(ticket.spender), ErrorsLib.ValidationBodyMismatch(ticketId));
    }

    /// @dev No ticket is opened or sent over a receipt waiting for it: it answers no copy home sent, and is booked on
    ///  hold once it can be, never applied as this ticket's move.
    function _requireNoReceiptWaitsForTheTicket(ValidationStorage storage store, bytes32 ticketId) private view {
        ITickets.WaitingReceipt storage waiting = store.waitingReceipts[MessageTypesLib.halfKeyOf(ticketId, 0)];
        require(waiting.bodyHash == bytes32(0), ErrorsLib.ApplyWaitingReceiptFirst(ticketId, waiting.chainKey));
    }

    /// @dev Whether a ticket that left may be sent again now, see {sendTicket}, and whether this send is an ask for its
    ///  receipt: before its valid until a resend, from {waitingEndsAtOf} an ask, never in between; and one waiting
    ///  time after the last send either way, so a late caller cannot send two at once. A bring home has no ticket to
    ///  send: its half is sent again with {SecondHalfLib-sendSecondHalf}.
    /// @return anAsk whether the send is an ask for the receipt
    function _requireCanBeSentAgain(ITickets.Ticket storage ticket, bytes32 ticketId)
        private
        view
        returns (bool anAsk)
    {
        ITickets.TicketStatus status = ticket.status;
        require(status == ITickets.TicketStatus.Open, ErrorsLib.ValidationNotResendable(ticketId, uint8(status)));
        bool aMove = ticket.kind == ITickets.TicketKind.MOVE;
        require(aMove, ErrorsLib.ValidationNotResendable(ticketId, uint8(status)));
        uint64 waitingEndsAt = waitingEndsAtOf(ticket);
        anAsk = block.timestamp >= waitingEndsAt;
        bool aResend = block.timestamp < ticket.validUntil;
        require(anAsk || aResend, ErrorsLib.SendNotDue(ticketId, waitingEndsAt));
        uint64 oneWaitingTimeAfterTheLastSend = ticket.lastSentAt + layout().waitingTimes[ticket.fromChainKey];
        require(
            block.timestamp >= oneWaitingTimeAfterTheLastSend,
            ErrorsLib.SendNotDue(ticketId, oneWaitingTimeAfterTheLastSend)
        );
        if (anAsk) require(ticket.asksForReceipt < MAX_RECEIPT_ASKS, ErrorsLib.NoAsksLeft(ticketId));
    }

    /// @dev The later of `validUntil` and `seenValidUntil`, plus the sender's away chain's waiting time, read now: from
    ///  then on the receipt is overdue and may be asked for. A change of the setting moves it for tickets already out.
    function waitingEndsAtOf(ITickets.Ticket storage ticket) internal view returns (uint64) {
        uint64 latestValidUntil = ticket.validUntil;
        if (ticket.seenValidUntil > latestValidUntil) latestValidUntil = ticket.seenValidUntil;
        return latestValidUntil + layout().waitingTimes[ticket.fromChainKey];
    }

    /// @dev The waiting time of the chain the move's first message goes to. The token must be running, and that chain
    ///  open and configured: this is where a request is refused with `TokenPaused`.
    function _openTheFirstChain(address token, bytes32 firstChainKey) private view returns (uint64 window) {
        requireTokenRunning(token);
        window = _openChainWindow(layout(), token, firstChainKey);
    }

    /// @dev A move from one away chain to another involves the receiver's chain too: like the first chain, it must not
    ///  be blocked, have no hostile change running, and keep an open receipt route, or its second half could not
    ///  leave. A receiver at home or on the first chain adds no chain.
    function _requireTheReceiversChainOpen(address token, bytes32 firstChainKey, bytes calldata to) private view {
        (bool toHome,) = WalletKeyLib.isReferenceChain(to);
        bytes32 toChainKey = _chainKeyOf(to);
        bool toAnotherAwayChain = !toHome && toChainKey != firstChainKey;
        if (!toAnotherAwayChain) return;
        requireAwayChainNotBlocked(toChainKey);
        requireNoHostileChange(token, toChainKey);
        require(ITREXMessaging(token).isChainOpen(toChainKey), ErrorsLib.ChainNotOpen(toChainKey));
    }

    /// @dev The waiting time of a chain a ticket may go to: not blocked, no hostile change running, and a window
    ///  configured.
    function _openChainWindow(ValidationStorage storage store, address token, bytes32 chainKey)
        private
        view
        returns (uint64 window)
    {
        requireAwayChainNotBlocked(chainKey);
        requireNoHostileChange(token, chainKey);
        window = store.waitingTimes[chainKey];
        require(window != 0, ErrorsLib.WaitingTimeNotSet(chainKey));
    }

    /* ----- Settings ----- */

    /// @dev See {ITickets-setValidityWindows}.
    function setValidityWindows(uint64 onTicketRoute, uint64 onReceiptRoute) external {
        _requireValidityWindowAtMostTheLongest(onTicketRoute);
        _requireValidityWindowAtMostTheLongest(onReceiptRoute);
        layout().validityWindows =
            ITickets.ValidityWindows({ onTicketRoute: onTicketRoute, onReceiptRoute: onReceiptRoute });
        emit EventsLib.ValidityWindowsSet(onTicketRoute, onReceiptRoute);
    }

    /// @dev See {ITickets-setWaitingTime}.
    function setWaitingTime(bytes32 chainKey, uint64 duration) external {
        ValidationStorage storage store = layout();
        _requireWaitingTimeAboveTheFloors(chainKey, duration, store.measuredTimes[chainKey]);
        store.waitingTimes[chainKey] = duration;
        emit EventsLib.WaitingTimeSet(chainKey, duration);
    }

    /// @dev See {ITickets-setMeasuredTimes}. A waiting time already set must stay above the floor the new times give.
    function setMeasuredTimes(bytes32 chainKey, ITickets.MeasuredTimes calldata times) external {
        ValidationStorage storage store = layout();
        uint64 waitingTime = store.waitingTimes[chainKey];
        if (waitingTime != 0) _requireWaitingTimeAboveTheFloors(chainKey, waitingTime, times);

        store.measuredTimes[chainKey] = times;
        emit EventsLib.MeasuredTimesSet(chainKey, times);
    }

    /// @dev A validity window at most the longest allowed: how old the rules may be when an away token executes.
    function _requireValidityWindowAtMostTheLongest(uint64 duration) private pure {
        uint64 longest = LONGEST_VALIDITY_WINDOW;
        require(duration <= longest, ErrorsLib.ValidityWindowOutOfRange(duration, longest));
    }

    /// @dev The floors of a waiting time: at least one hour; and strictly above the full finality delivery plus the
    ///  clock lead, so a second half arrives before its valid until on a clock that runs ahead, strictly since the
    ///  away token executes strictly before valid until. The other conditions on a waiting time are sized off chain.
    function _requireWaitingTimeAboveTheFloors(bytes32 chainKey, uint64 duration, ITickets.MeasuredTimes memory times)
        private
        pure
    {
        uint64 belowOneHour = MIN_WAITING_TIME - 1;
        require(duration > belowOneHour, ErrorsLib.WaitingTimeTooShort(chainKey, duration, belowOneHour));
        uint64 secondHalfFloor = times.fullFinalityDelivery + times.clockLead;
        require(duration > secondHalfFloor, ErrorsLib.WaitingTimeTooShort(chainKey, duration, secondHalfFloor));
    }

    /// @dev Nothing goes out while the token is paused: an incident is under investigation, every receipt waits
    ///  here unapplied, so a ticket sent now could only be executed on an away chain with its receipt held, and
    ///  its window could run out before the pause is lifted. Ask, approval and ask for the receipt alike. For the same
    ///  reason no ticket whose receipt may be waiting is cancelled under it, see {requireTicketCanBeDecided}.
    function requireTokenRunning(address token) internal view {
        require(!IToken(token).paused(), ErrorsLib.TokenPaused());
    }

    /// @dev Nothing goes toward a blocked away chain: its receipts wait here unapplied, so a ticket sent now could
    ///  only add to what cannot be applied, see {ITickets-blockAwayChain}.
    function requireAwayChainNotBlocked(bytes32 chainKey) internal view {
        require(!layout().blockedAwayChains[chainKey], ErrorsLib.AwayChainBlocked(chainKey));
    }

    /// @dev Nothing is decided about a ticket while the away chain that owes its receipt is blocked. The receipts
    ///  waiting from that chain may already answer it: cancelling on their absence would release what they move.
    ///  The token's own pause holds every chain's receipts the same way, so nothing is decided under it either: a
    ///  pause that outlasts `waitingEndsAt` would otherwise release a reservation whose receipt is waiting, and the
    ///  room it frees could be reserved again before that receipt is applied. Nor while a hostile change runs on
    ///  that chain, see {requireNoHostileChange}.
    function requireTicketCanBeDecided(address token, ITickets.Ticket storage ticket) internal view {
        requireTokenRunning(token);
        requireAwayChainNotBlocked(ticket.fromChainKey);
        requireNoHostileChange(token, ticket.fromChainKey);
    }

    /// @dev Nothing is asked, sent or cancelled for an away chain whose peer was replaced as hostile, until four of
    ///  its waiting times have passed: home keeps no former pair then, so an honest receipt still on the old pair is
    ///  refused until the away token switches, and a cancel meanwhile could release a ticket it executed. Its
    ///  receipts still land. The freeze is the token's, see {ITREXMessaging-hostileChangeEndsAt}.
    function requireNoHostileChange(address token, bytes32 chainKey) internal view {
        uint64 endsAt = ITREXMessaging(token).hostileChangeEndsAt(chainKey);
        require(block.timestamp >= endsAt, ErrorsLib.HostileChangeNotOver(chainKey, endsAt));
    }

    /// @dev Blocks an away chain. The same state again changes nothing and emits nothing.
    function blockAwayChain(bytes32 chainKey) internal {
        ValidationStorage storage store = layout();
        if (store.blockedAwayChains[chainKey]) return;
        store.blockedAwayChains[chainKey] = true;
        emit EventsLib.AwayChainBlockSet(chainKey, true);
    }

    /// @dev Lifts the block of an away chain. The same state again changes nothing and emits nothing.
    function unblockAwayChain(bytes32 chainKey) internal {
        ValidationStorage storage store = layout();
        if (!store.blockedAwayChains[chainKey]) return;
        store.blockedAwayChains[chainKey] = false;
        emit EventsLib.AwayChainBlockSet(chainKey, false);
    }

    /// @dev Whether the id was taken: a ticket, a bring home, or a record a receipt with no ticket wrote. Every record
    ///  names its sender's wallet key, a hash that is never zero, so that field says whether the slot was written. The
    ///  sender's identity would not: a receipt can name a wallet linked to none.
    function isRecorded(ValidationStorage storage store, bytes32 ticketId) internal view returns (bool) {
        return store.validations[ticketId].fromKey != bytes32(0);
    }

    /// @dev The id of a ticket: a hash of the whole request, never of the block it is mined in. The same request
    ///  gets the same id in any block, so a ticket sent before a reorg keeps its id when the ask is mined again.
    ///  `requestedMax` is the maximum as asked: home narrows `amountMax` from the state of the block, so it is left
    ///  out. `spenderKey` is {spenderKeyOf} the spender's envelope.
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

    /// @dev The key of a spender in a ticket id: `keccak256` of its envelope, zero when there is none, so the away
    ///  token builds the id of a ticket that names no spender without hashing an empty envelope.
    function spenderKeyOf(bytes memory spender) internal pure returns (bytes32) {
        if (spender.length == 0) return bytes32(0);
        return keccak256(spender);
    }

    /// @dev The ask block hash: names the copy of a ticket written in this block, the ask's own block, for every
    ///  ticket, one that waits for approval included. Two copies of one ask mined in two blocks share the id and
    ///  differ here; two sibling blocks share number and parent, so the terms are in it too.
    function askBlockHashOf(uint256 amountMax, uint64 validUntil) internal view returns (bytes32) {
        return keccak256(abi.encode(block.number, blockhash(block.number - 1), amountMax, validUntil));
    }

    function layout() internal pure returns (ValidationStorage storage $) {
        assembly ("memory-safe") {
            $.slot := VALIDATION_STORAGE_LOCATION
        }
    }

    /// @dev Discards a move still `WaitingForApproval` once its deadline passed, for anyone, see
    ///  {ITickets-cancelTickets}. Nothing was sent for it, so no honest receipt can be in flight. The reservation comes
    ///  back. A ticket the approver opened is cancelled only once an ask for its receipt went unanswered.
    /// @param token the token the compliance is bound to
    function discardUnanswered(bytes32 ticketId, address token) internal {
        ITickets.Ticket storage ticket = layout().validations[ticketId];
        require(block.timestamp >= ticket.validUntil, ErrorsLib.CancelNotDue(ticketId, ticket.validUntil));
        moveTo(ticket, ITickets.TicketStatus.Cancelled, token);
        emit EventsLib.TicketCancelled(ticketId);
    }

    /// @dev Whether a move was written and never sent: waiting for approval, or opened by the approver and not sent
    ///  yet. `sent` is written at the first send, see {_issueRecorded}.
    function neverSent(ITickets.Ticket storage ticket) internal view returns (bool) {
        bool aMove = ticket.kind == ITickets.TicketKind.MOVE;
        return aMove && !ticket.sent && _holdsTheAsk(ticket.status);
    }

    /// @dev Keeps the ticket forever and reserves its amount, with the route chosen for it and the ask block hash of
    ///  the ask's own block. Everything written here is the issuance half of the lifecycle; `sent` is written at the
    ///  first send, see {_issueRecorded}. A ticket on the ticket route counts in that route's window.
    function _record(bytes32 ticketId, bytes calldata from, bytes calldata spender, Draft memory draft, address token)
        private
    {
        ITickets.Ticket storage stored = layout().validations[ticketId];
        stored.amountMin = draft.amountMin;
        stored.amountMax = draft.amountMax;
        stored.validUntil = draft.validUntil;
        draft.askBlockHash = askBlockHashOf(draft.amountMax, draft.validUntil);
        stored.askBlockHash = draft.askBlockHash;
        stored.stopWaitingAt = draft.validUntil + 4 * draft.waitingTime;
        stored.fromChainKey = draft.fromChainKey;
        stored.toChainKey = draft.toChainKey;
        stored.fromKey = draft.fromKey;
        stored.fromWallet = from;
        stored.toKey = draft.toKey;
        stored.fromIdentity = draft.fromIdentity;
        stored.toIdentity = draft.toIdentity;
        stored.spender = spender;
        stored.requestedMax = draft.requestedMax;
        stored.onReceiptRoute = draft.onReceiptRoute;
        stored.waitedForApproval = draft.waitedForApproval;
        // Open unless an approval module is bound, see {_awaitApproval}.
        stored.status = ITickets.TicketStatus.Open;
        stored.written = true;
        // `reservePending` returns whether it reserved against the identities; it does not on a relocation.
        stored.relocation = !ComplianceLedgerLib.reservePending(
            draft.fromIdentity, draft.toIdentity, draft.fromChainKey, draft.amountMax
        );

        ValidationStorage storage store = layout();
        if (stored.stopWaitingAt > store.latestStopWaitingAt) store.latestStopWaitingAt = stored.stopWaitingAt;
        _countTheAsk(store, draft.fromIdentity);
        if (!draft.onReceiptRoute) _countOnTheTicketRoute(store, draft);

        // A home wallet's tokens are burned in the ask itself, or at the first send after the approval, so nothing is
        // reserved on the token.
        if (draft.homeWallet == address(0)) IToken(token).reserveForTicket(from, draft.amountMax);
    }

    /// @dev Marks the ticket sent, announces the copy the away token will execute against, and encodes it. Run once,
    ///  at the first send: `sent` is what says the ticket left.
    function _issueRecorded(bytes32 ticketId, MessageTypesLib.TicketMessage memory issued)
        private
        returns (bytes memory body)
    {
        layout().validations[ticketId].sent = true;

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

    /// @dev Sends a written ticket to the sender's away chain on the route chosen at its ask. When that chain already
    ///  answered an ask mined again after a reorg, the away token answers this copy with the receipt it stored. The
    ///  token is the wire's only author: it pins the half and refuses a closed chain. As the compliance's DELEGATECALL
    ///  target, this library reaches the token with the compliance as the caller.
    function _dispatch(address token, bytes32 ticketId, bytes32 fromChainKey, bytes memory body) private {
        ITickets.Ticket storage ticket = layout().validations[ticketId];
        ticket.lastSentAt = uint64(block.timestamp);
        _sendOnItsRoute(token, ticket.onReceiptRoute, ticketId, fromChainKey, body);
    }

    /// @dev Hands a ticket to the token on the route chosen at its ask: the receipt route, at full finality, or the
    ///  ticket route. The token falls back from a ticket bridge it no longer trusts to the receipt route, never the
    ///  other way.
    function _sendOnItsRoute(address token, bool onReceiptRoute, bytes32 ticketId, bytes32 chainKey, bytes memory body)
        private
    {
        if (onReceiptRoute) {
            bytes32 halfKey = MessageTypesLib.halfKeyOf(ticketId, 0);
            IToken(token).sendOnReceiptRoute(chainKey, halfKey, MessageTypesLib.Message.TICKET, body);
            return;
        }
        IToken(token).sendOnTicketRoute(chainKey, ticketId, body);
    }

    /// @dev Keeps a recorded ticket waiting for the approval module, and tells the module. The validity window
    ///  of the receipt route from now is the deadline for the answer and for the first send after it.
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

        emit EventsLib.TicketWaitingForApproval(
            ticketId, from, to, spender, draft.amountMin, draft.amountMax, draft.validUntil
        );

        IModule.TransferContext memory transferContext = TransferContextLib.issuance(
            draft.fromChainKey,
            draft.fromIdentity,
            draft.toIdentity,
            draft.fromKey,
            WalletKeyLib.walletId(to),
            draft.amountMin,
            draft.amountMax,
            spender
        );
        IApprovalModule(approvalModule).approvalRequested(ticketId, transferContext, draft.validUntil);
    }

    /// @dev Moves a ticket to `next` and releases what its old row of the table holds and the new row does not.
    ///  The table, one row per state:
    ///  - `WaitingForApproval`, `Open`: the ask's `amountMax`, reserved in the ledger's total, against both
    ///    identities unless both wallets are one identity's, and against the sender's away wallet on the token. An
    ///    open bring home is one identity's two wallets, so it holds its amount in the total and on its away wallet;
    ///  - `OnHold`: `moved`, reserved in the ledger's total, against the receiver's identity when the money goes
    ///    to the receiver and the two wallets are not one identity's, and as on hold forward from the chain it left
    ///    when it goes to the receiver. Written by {reserveTheHold} once the destination is known, since the rules
    ///    judge the receiver between the ask's release and this write;
    ///  - `Cancelled`, `Done`: nothing.
    ///  The first two rows also count as one of the sender's identity's open tickets, see {ITickets-AskLimits}.
    ///  The release is read off the two rows, so it runs exactly once and is never skipped.
    function moveTo(ITickets.Ticket storage ticket, ITickets.TicketStatus next, address token) internal {
        ITickets.TicketStatus previous = ticket.status;
        ticket.status = next;
        bool leavesTheAsk = _holdsTheAsk(previous) && !_holdsTheAsk(next);
        if (leavesTheAsk) {
            layout().identityAsks[ticket.fromIdentity].openTickets -= 1;
            _release(ticket, ticket.amountMax, token);
        }
        bool leavesTheHold = previous == ITickets.TicketStatus.OnHold && next != ITickets.TicketStatus.OnHold;
        if (leavesTheHold) _releaseTheHold(ticket);
    }

    /// @dev Writes the `OnHold` row of {moveTo}'s table, once `secondHalfToKey` names where the money goes.
    function reserveTheHold(ITickets.Ticket storage ticket) internal {
        ComplianceLedgerLib.Ledger storage ledger = ComplianceLedgerLib.layout();
        ledger.pendingTotal += ticket.moved;
        if (_holdGoesForward(ticket)) ledger.onHoldForward[ticket.fromChainKey] += ticket.moved;
        if (_holdReservesForTheReceiver(ticket)) ledger.pendingIn[ticket.toIdentity] += ticket.moved;
    }

    /// @dev Turns money on hold back toward its sender: the `OnHold` row is written again for the new destination,
    ///  so nothing stays kept against the receiver. The halves sent so far went to the receiver, which judges their
    ///  late answers.
    function turnTheHoldBack(ITickets.Ticket storage ticket) internal {
        _releaseTheHold(ticket);
        ticket.lastHalfToTheReceiver = ticket.half;
        ticket.secondHalfToKey = ticket.fromKey;
        reserveTheHold(ticket);
    }

    /// @dev Gives back the `OnHold` row of {moveTo}'s table.
    function _releaseTheHold(ITickets.Ticket storage ticket) private {
        ComplianceLedgerLib.Ledger storage ledger = ComplianceLedgerLib.layout();
        ledger.pendingTotal -= ticket.moved;
        if (_holdGoesForward(ticket)) ledger.onHoldForward[ticket.fromChainKey] -= ticket.moved;
        if (_holdReservesForTheReceiver(ticket)) ledger.pendingIn[ticket.toIdentity] -= ticket.moved;
    }

    /// @dev Whether the money on hold of a ticket goes on to its receiver. Money on hold with no ticket goes to
    ///  nobody: while it is cancelled, its half burns from the receiver.
    function _holdGoesForward(ITickets.Ticket storage ticket) private view returns (bool) {
        bool goesToTheReceiver = ticket.secondHalfToKey == ticket.toKey;
        return goesToTheReceiver && ticket.written;
    }

    /// @dev Whether the money on hold is kept against the receiver's identity: it goes forward, and the two wallets
    ///  are not one identity's.
    function _holdReservesForTheReceiver(ITickets.Ticket storage ticket) private view returns (bool) {
        return _holdGoesForward(ticket) && !ticket.relocation;
    }

    /// @dev Whether a half that burns is out for the ticket: an open bring home's, or the bring home of a cancel of
    ///  money on hold with no ticket, sent and not yet answered.
    function aBringHomeIsOut(ITickets.Ticket storage ticket) internal view returns (bool) {
        bool anOpenBringHome =
            ticket.kind == ITickets.TicketKind.BRING_HOME && ticket.status == ITickets.TicketStatus.Open;
        if (anOpenBringHome) return true;
        bool burnsFromTheReceiver = !ticket.written && ticket.secondHalfToKey == ticket.toKey;
        bool notAnswered = !ticket.secondHalfOwed && !ticket.shortCancel;
        return ticket.status == ITickets.TicketStatus.OnHold && burnsFromTheReceiver && notAnswered;
    }

    /// @dev What the latest second half moves: the money on hold, or, while money on hold with no ticket is
    ///  cancelled, what that cancel's half moves.
    function amountOfTheLatestHalf(ITickets.Ticket storage ticket) internal view returns (uint256) {
        if (!ticket.written) return ticket.amountMax;
        return ticket.moved;
    }

    /// @dev Whether a ticket in `status` holds the ask's reservation: the table of {moveTo}.
    function _holdsTheAsk(ITickets.TicketStatus status) private pure returns (bool) {
        return status == ITickets.TicketStatus.WaitingForApproval || status == ITickets.TicketStatus.Open;
    }

    /// @dev Gives back `amount` of what a ticket reserved: in the ledger's total and its chain's, against the identities unless both
    ///  wallets are one identity's, and against the sending away wallet on the token. {moveTo} gives back a whole
    ///  row; an approver's narrowing gives back part of it. A home wallet reserved nothing on the token.
    function _release(ITickets.Ticket storage ticket, uint256 amount, address token) private {
        ComplianceLedgerLib.Ledger storage ledger = ComplianceLedgerLib.layout();
        ledger.pendingTotal -= amount;
        ledger.reservedFrom[ticket.fromChainKey] -= amount;
        if (!ticket.relocation) {
            ledger.pendingOut[ticket.fromIdentity] -= amount;
            ledger.pendingIn[ticket.toIdentity] -= amount;
        }
        (bool fromHome,) = WalletKeyLib.isReferenceChain(ticket.fromWallet);
        if (!fromHome) IToken(token).releaseFromTicket(ticket.fromWallet, amount);
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
