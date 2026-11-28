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

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";

import { ITickets } from "../compliance/modular/ITickets.sol";
import { IModule } from "../compliance/modular/modules/IModule.sol";
import { ITREXImplementationAuthority } from "../proxy/beacon/ITREXImplementationAuthority.sol";
import { MessageTypesLib } from "./MessageTypesLib.sol";
import { Version } from "./VersionLib.sol";

library EventsLib {

    // Common Events

    event ImplementationAuthoritySet(address implementationAuthority);

    // Token Events

    /// A validation being issued reserved part of a satellite wallet's bridged balance.
    event ReservedForValidation(bytes32 indexed walletKey, bytes wallet, uint256 amount);

    /// A reservation against a satellite wallet was given back, because the ticket left its open row: a receipt
    /// or a cancel.
    event ReleasedFromValidation(bytes32 indexed walletKey, bytes wallet, uint256 amount);

    /// @notice Emitted when the money of a move goes on hold between its two halves: an away chain burned it from
    ///         `fromWallet`, or a home wallet that moves out burned it at home.
    event HeldInTransit(bytes32 indexed fromKey, bytes32 indexed ticketId, bytes fromWallet, uint256 amount);
    /// @notice Emitted when a move ends on an away wallet, from the sender's away balance or from the move's hold.
    event BridgedTransfer(
        bytes32 indexed fromKey, bytes32 indexed toKey, bytes32 indexed ticketId, bytes from, bytes to, uint256 amount
    );
    /// @notice Emitted on a settled movement leaving a satellite wallet for a native one, under the ticket it
    ///  consumed: a move, or a bring home, which keeps its owner.
    event SettledToNative(
        bytes32 indexed fromKey, address indexed to, bytes32 indexed ticketId, bytes fromWallet, uint256 amount
    );

    // ModularCompliance Events

    event ModuleInteraction(address indexed target, bytes data);
    event ModuleAdded(address indexed module);
    event ModuleTypesRecorded(address indexed module, IModule.ModuleType[] moduleTypes);
    event ModuleRemoved(address indexed module);
    event ModuleForceRemoved(address indexed module);

    // AbstractModule / AbstractModuleUpgradeable Events

    event ComplianceBound(address indexed compliance);
    event ComplianceUnbound(address indexed compliance);

    // IdentityRegistry / IdentityRegistryStorage Events
    // ClaimTopicsRegistry Events

    event ClaimTopicAddedForIdentityType(uint256 indexed identityType, uint256 indexed claimTopic);
    event ClaimTopicRemovedForIdentityType(uint256 indexed identityType, uint256 indexed claimTopic);

    // IdentityRegistry Events

    event EligibilityChecksDisabled();
    event EligibilityChecksEnabled();
    /// @notice A wallet's binding was revoked, like the IdentityFactory's `AccountRevoked`. The wallet keeps
    ///         `identity` but may no longer act, and it can never be bound again. Emitted by the storage and
    ///         by the registry in place of the standard `IdentityUnstored` and `IdentityRemoved`, which mean
    ///         the wallet left the registry.
    event IdentityRevoked(address indexed investor, IIdentity indexed identity);

    // Token Events
    event ForcedTransfer(address indexed agent);
    event IdentityTransfer(address indexed identity, address indexed from, address indexed to, uint256 amount);

    // TREXFactory Events

    event Deployed(address indexed addr);
    event IdFactorySet(address idFactory);

    event TREXSuiteDeployed(address indexed token, address registry, address irs, address mc, string salt);
    event IsolatedSuiteDeployed(address indexed token, ITREXImplementationAuthority.SuiteBeacons beacons);

    // TrustedGatewayRegistry Events

    /// @notice Emitted when `bridge` is trusted at `depth` (zero is full finality), or distrusted for good.
    event TrustedGatewaySet(address indexed bridge, bool trusted, uint64 depth);

    // TREXMessaging Events

    /// @notice Emitted by the factory when its registry pointer moves, and by a token once, at deployment.
    event TrustedGatewayRegistrySet(address trustedGatewayRegistry);
    /// @notice Emitted the first time a token learns the ERC-7930 prefix behind a `chainKey`.
    event ChainRegistered(bytes32 indexed chainKey, bytes2 chainType, bytes chainReference);
    /// @notice Emitted when the receipt route of `chainKey` is set to `bridge`. The away chain's CCIP selector and
    ///  its receipt bridge are what the token asks `bridge`'s receiving policy about.
    event ReceiptRouteSet(
        bytes32 indexed chainKey, address indexed bridge, uint64 awayChainSelector, bytes awayReceiptBridge
    );
    /// @notice Emitted when the receipt route of `chainKey` is closed: nothing is sent to or taken from that chain.
    event ReceiptRouteClosed(bytes32 indexed chainKey);
    /// @notice Emitted when the ticket route of `chainKey`, which carries tickets only, is set; zero unsets it.
    event TicketRouteSet(bytes32 indexed chainKey, address indexed gateway);
    event PeerSet(bytes32 indexed chainKey, bytes peer);
    /// @notice Emitted when a planned change keeps the route and peer `chainKey` had as its former pair, taken for
    ///  every receipt until `acceptedUntil`, with the waiting time as it is at the change: a later change of the
    ///  waiting time moves that end.
    event FormerRouteKept(bytes32 indexed chainKey, address indexed bridge, bytes32 peerKey, uint64 acceptedUntil);
    /// @notice Emitted when the peer of `chainKey` is replaced as hostile: no former pair is kept, and asks, ticket
    ///  sends and cancels for that away chain wait until `endsAt`, with the waiting time as it is at the change: a
    ///  later change of the waiting time moves that end, see {ITREXMessaging-hostileChangeEndsAt}.
    event HostilePeerReplaced(bytes32 indexed chainKey, bytes peer, uint64 endsAt);
    /// @notice Emitted when the half `halfKey` toward `chainKey` is pinned to `gateway`, the chain's receipt route
    ///         when it left, and to the peer it went to, whichever route carried it out. Half 0's key is the ticket
    ///         id, see {MessageTypesLib-halfKeyOf}.
    event HalfPinned(bytes32 indexed halfKey, bytes32 indexed chainKey, address gateway);
    event ProtocolMessageSent(MessageTypesLib.Message indexed messageType, bytes32 indexed chainKey, bytes32 sendId);
    event ProtocolMessageReceived(
        MessageTypesLib.Message indexed messageType, bytes32 indexed chainKey, bytes32 receiveId
    );

    // ModularCompliance Interop Events

    /// @notice Emitted by the compliance when the token hands it an attributed settlement notification.
    event ReceiptReceived(
        bytes32 indexed originChainKey, bytes32 indexed ticketId, bytes from, bytes to, uint256 amount
    );

    // Tickets Events
    /// @notice The two validity windows were set: for tickets on the ticket route, and on the receipt route.
    event ValidityWindowsSet(uint64 onTicketRoute, uint64 onReceiptRoute);
    event WaitingTimeSet(bytes32 indexed chainKey, uint64 duration);
    /// @notice The measured times of the away chain `chainKey` were set.
    event MeasuredTimesSet(bytes32 indexed chainKey, ITickets.MeasuredTimes times);
    /// @notice New asks were paused or resumed for the away chain `chainKey`, or for every chain when it is zero.
    event AsksPausedSet(bytes32 indexed chainKey, bool paused);
    /// @notice The limits on asks were set.
    event AskLimitsSet(ITickets.AskLimits limits);
    /// @notice The ask limit of one identity was set; zero gives it the token's limit again.
    event AskLimitOfSet(address indexed identity, uint32 asksPerWindow);
    /// @notice Anyone asked the away token for the receipt of `ticketId`; `askNumber` counts the asks that stand.
    event ReceiptAsked(bytes32 indexed ticketId, uint8 askNumber);
    /// @notice The away token answered that `ticketId` is still open; `seenValidUntil` is the latest valid until it
    ///         reported, within home's cap.
    event TicketStillOpen(bytes32 indexed ticketId, uint64 seenValidUntil);
    /// @notice The second half `half` of `ticketId` left for `wallet` on `chainKey`: a move out of `amount`, which the
    ///         away token mints strictly before `validUntil` on its own clock.
    event SecondHalfSent(
        bytes32 indexed ticketId, uint8 half, bytes32 indexed chainKey, bytes wallet, uint256 amount, uint64 validUntil
    );
    /// @notice The send of the second half `half` of `ticketId`, tried inside its receipt's delivery, failed. The half
    ///         stays owed: anyone sends it with `sendSecondHalf`.
    event SecondHalfNotSent(bytes32 indexed ticketId, uint8 half);
    /// @notice A receipt from `chainKey` for `ticketId`, which no ticket home sent answers, put `amount` on hold under
    ///         `from` with no destination. When `to` is on the same away chain, `amount` is its uncounted credit.
    event ReceiptWithoutTicket(
        bytes32 indexed ticketId, bytes32 indexed chainKey, bytes from, bytes to, uint256 amount
    );
    /// @notice A receipt from `chainKey` for a second half `halfKey` of an id home has no record of was refused.
    ///         Nothing is written and no chain is blocked.
    event ReceiptUnknown(bytes32 indexed halfKey, bytes32 indexed chainKey);
    /// @notice The ask mined again took the money on hold with no ticket under `ticketId`.
    event HoldTaken(bytes32 indexed ticketId);
    /// @notice The cancel of the money on hold with no ticket under `ticketId` started.
    event HoldCancelled(bytes32 indexed ticketId);
    /// @notice The cancel of the money on hold under `ticketId` burned `missing` less than it holds: that rest stays
    ///         on hold under the sender until carried credit comes back to the receiver, or a human acts.
    event CancelHoldShort(bytes32 indexed ticketId, uint256 missing);
    /// @notice A human closed `ticketId` by hand from a read of its closed away chain. `returnedAmount` went back
    ///         toward the sender; zero when the read receipt was applied, a ticket cancelled or a bring home ended.
    ///         `awayBlockNumber` and `awayClockTime` name the final block read, which the caller's role attests.
    event ClosedByHand(bytes32 indexed ticketId, uint256 returnedAmount, uint64 awayBlockNumber, uint64 awayClockTime);
    /// @notice The block of the away chain `chainKey` was set to `blocked`. Set by the pauser on suspicion, or by the
    ///         compliance on a bad receipt or receipt terms it broke: no ticket goes to it, none of its tickets is
    ///         cancelled, and its receipts wait. Lifted by the pauser, after an investigation.
    event AwayChainBlockSet(bytes32 indexed chainKey, bool blocked);
    /// @notice Emitted on issuance with the full envelopes, the asked and the final bounds, and the ask block hash
    ///         of the copy sent, so indexers need no reverse table.
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
    /// @notice Emitted when a ticket is cancelled and its reservation released.
    event TicketCancelled(bytes32 indexed ticketId);
    /// @notice Emitted when a validation is recorded and reserved while an `APPROVAL` module decides it.
    event TicketWaitingForApproval(
        bytes32 indexed ticketId,
        bytes from,
        bytes to,
        bytes spender,
        uint256 amountMin,
        uint256 amountMax,
        uint64 deadline
    );
    /// @notice Emitted when a validation awaiting approval is refused, or left unanswered past its deadline, and
    ///         its reservation released.
    event ValidationApprovalRefused(bytes32 indexed ticketId);
    /// @notice Emitted when the caps on tickets toward `chainKey` are set.
    event TicketLimitsSet(bytes32 indexed chainKey, uint256 perTicketCap, uint256 perWindowCap);

    /// The registry now names another identity for an empty wallet, and the ledger took note. `amount` is what
    /// moved between the two positions, zero: a wallet that holds tokens never changes identity in the ledger.
    event WalletOwnerChanged(
        address indexed wallet, address indexed previousIdentity, address indexed identity, uint256 amount
    );

    /// @notice Emitted when a receipt was applied: the ticket is done and the ledger moved by `amount`, zero for a
    ///         receipt that moved nothing.
    event ReceiptApplied(bytes32 indexed ticketId, bytes32 indexed chainKey, uint256 amount);
    /// @notice The receipt home already holds for this half came again from `chainKey`, byte for byte, under
    ///         another receive id: a bridge delivering twice, or an away token sending its stored receipt again.
    ///         Nothing changes; the delivery is consumed.
    event ReceiptDuplicate(bytes32 indexed ticketId, bytes32 indexed chainKey);
    /// @notice A good receipt from `chainKey` that cannot be applied yet waits under its half, tagged with the
    ///         `bridge` that delivered it. Home keeps only its hash: `receipt` is the copy a later caller gives back
    ///         to `applyWaitingReceipt`.
    event ReceiptWaiting(
        bytes32 indexed halfKey, bytes32 indexed chainKey, address bridge, MessageTypesLib.ReceiptMessage receipt
    );
    /// @notice The receipt waiting under `halfKey` from `chainKey` was applied.
    event WaitingReceiptApplied(bytes32 indexed halfKey, bytes32 indexed chainKey);
    /// @notice The pauser deleted the receipt waiting under `halfKey` while its away chain was blocked.
    event WaitingReceiptRefused(bytes32 indexed halfKey);
    /// @notice A bad receipt from `chainKey`, refused for `reason`: another body for a half that has one, from a chain
    ///         that is not the sender's, for wallets that are not the ticket's, for a half never sent, or an expired
    ///         answer that moved something. Nothing is applied, and the compliance blocks `chainKey`.
    event ReceiptRefused(
        bytes32 indexed ticketId,
        bytes32 indexed chainKey,
        uint256 amount,
        bytes32 askBlockHash,
        ITickets.ReceiptRefusal reason
    );
    /// @notice A receipt from `chainKey` answers a copy of the ticket from another home block, one a home reorg
    ///         dropped: it is applied as it happened, and blocks `chainKey` only above `requestedMax` or the away
    ///         chain's per-ticket cap. `seenMax` is the maximum of the copy the away token executed.
    event ReceiptOnOlderTerms(bytes32 indexed ticketId, bytes32 indexed chainKey, uint256 seenMax);
    /// @notice A receipt from `chainKey` was applied although the rules would not allow `amount` now: the away
    ///         token's balances already moved, so home records it and says so.
    event MoveBreachedRule(bytes32 indexed ticketId, bytes32 indexed chainKey, uint256 amount);
    // TREXAccessManager Events

    event DomainCreated(uint32 indexed domainId, string name);
    event DomainAssigned(uint32 indexed domainId, address indexed target);

    // TREXImplementationAuthority Events

    event BeaconsDeployed(ITREXImplementationAuthority.SuiteBeacons beacons);
    event VersionPublished(Version version, ITREXImplementationAuthority.SuiteImplementations implementations);
    event SuiteUpgraded(Version version, ITREXImplementationAuthority.SuiteImplementations implementations);

}
