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

import { IModule } from "../compliance/modular/modules/IModule.sol";
import { ITrustedGatewayRegistry } from "../interop/ITrustedGatewayRegistry.sol";
import { ITREXImplementationAuthority } from "../proxy/beacon/ITREXImplementationAuthority.sol";
import { MessageTypesLib } from "./MessageTypesLib.sol";
import { Version } from "./VersionLib.sol";

library EventsLib {

    // Common Events

    event ImplementationAuthoritySet(address implementationAuthority);

    // Token Events

    /// @notice Emitted on a delegation-out. Carries the full envelope so indexers need no reverse key table, and the
    ///  delegation's id, which the mint instruction and any resend carry. Zero on a transition with no instruction.
    event DelegatedOut(
        address indexed holder, bytes32 indexed toKey, uint256 indexed delegationId, bytes toWallet, uint256 amount
    );
    /// @notice Emitted on a recall from a satellite wallet onto a native wallet.
    event Recalled(bytes32 indexed fromKey, address indexed holder, bytes fromWallet, uint256 amount);
    /// @notice Emitted when an agent orders a satellite to burn up to `amount` of `wallet`; the proof that answers
    ///  credits `nativeWallet`.
    event RecallInstructed(
        uint256 indexed recallId, bytes32 indexed walletKey, address indexed nativeWallet, bytes wallet, uint256 amount
    );
    /// @notice Emitted when a burn proof settles its recall. `amount` is what the satellite proved.
    event RecallSettled(uint256 indexed recallId, bytes32 indexed originChainKey, uint256 amount);
    /// @notice Emitted when the proof that already settled a recall is delivered again: nothing is applied.
    event BurnProofDuplicate(uint256 indexed recallId, bytes32 indexed originChainKey);
    /// @notice Emitted when a burn proof differs from the proof that settled its recall. Nothing is applied and the
    ///  compliance blocks `originChainKey`. A proof for a recall never issued reverts instead, and stops nothing.
    event ReplayedBurnProof(uint256 indexed recallId, bytes32 indexed originChainKey);
    /// @notice Emitted when an agent resends an instruction unchanged: `kind` 0 a delegation, 1 a recall.
    event InstructionResent(uint8 indexed kind, uint256 indexed id, bytes32 indexed chainKey, bytes32 sendId);
    /// @notice Emitted when the burn leg of a cross-chain validation takes the amount out of the sender's
    ///         position and holds it in transit until the mint leg lands.
    /// A validation being issued reserved part of a satellite wallet's bridged balance.
    event ReservedForValidation(bytes32 indexed walletKey, bytes wallet, uint256 amount);

    /// A reservation against a satellite wallet was given back, because the validation settled, was discarded,
    /// or turned into an in-transit hold.
    event ReleasedFromValidation(bytes32 indexed walletKey, bytes wallet, uint256 amount);

    /// A held amount went back to the wallet it was burned from.
    event ReturnedInTransit(bytes32 indexed walletKey, bytes32 indexed ticketId, bytes wallet, uint256 amount);

    event HeldInTransit(bytes32 indexed fromKey, bytes32 indexed ticketId, bytes fromWallet, uint256 amount);
    /// @notice Emitted on a settled movement between two satellite wallets, under the validation it consumed.
    event BridgedTransfer(
        bytes32 indexed fromKey, bytes32 indexed toKey, bytes32 indexed ticketId, bytes from, bytes to, uint256 amount
    );
    /// @notice Emitted on a settled movement leaving a satellite wallet for a native one, under the validation it
    ///  consumed. Ownership moves between identities, unlike {Recalled}.
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

    /// @notice Emitted when a reviewed bridge gets its one record: its standing and, for a ticket bridge, the
    ///  depth it waits for (zero is full finality).
    event BridgeTrusted(address indexed bridge, ITrustedGatewayRegistry.BridgeStanding standing, uint64 depth);
    /// @notice Emitted when a bridge is distrusted, for good.
    event BridgeDistrusted(address indexed bridge);

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
    /// @notice Emitted when the half of `ticketId` toward `chainKey` is pinned to `gateway`, the chain's receipt
    ///         route when it left, and to the peer it went to, whichever route carried the ticket out.
    event HalfPinned(bytes32 indexed ticketId, bytes32 indexed chainKey, address gateway);
    event ProtocolMessageSent(MessageTypesLib.Message indexed messageType, bytes32 indexed chainKey, bytes32 sendId);
    event ProtocolMessageReceived(
        MessageTypesLib.Message indexed messageType, bytes32 indexed chainKey, bytes32 receiveId
    );
    /// @notice Emitted by the token when an attributed burn proof reaches its recall path, before it is judged.
    event BurnProofReceived(
        bytes32 indexed originChainKey, uint256 indexed recallId, bytes burnedWallet, uint256 amount
    );

    // ModularCompliance Interop Events

    /// @notice Emitted by the compliance when the token hands it an attributed settlement notification.
    event ReceiptReceived(
        bytes32 indexed originChainKey, bytes32 indexed ticketId, bytes from, bytes to, uint256 amount
    );

    // Tickets Events
    event DefaultValidityWindowSet(uint64 duration);
    event WaitingTimeSet(bytes32 indexed chainKey, uint64 duration);
    /// @notice The compliance blocked the away chain `chainKey`: by the pauser on suspicion, on a bad receipt or
    ///         receipt terms it broke, or on a burn proof for a recall already settled. No ticket goes to it, none of
    ///         its tickets is cancelled, and its receipts wait.
    event AwayChainBlockStarted(bytes32 indexed chainKey);
    /// @notice The pauser lifted the block of the away chain `chainKey`, after an investigation.
    event AwayChainUnblocked(bytes32 indexed chainKey);
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
    /// @notice Emitted when the keeper discards an expired validation and its slots are released.
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
    /// @notice Emitted when an issued ticket is sent to `chainKey` again, byte for byte.
    event TicketSent(bytes32 indexed ticketId, bytes32 indexed chainKey);
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
    /// @notice A bad receipt from `chainKey`: another body for a half that has one, from a chain that is not the
    ///         sender's, for wallets that are not the ticket's, for a half never sent, or an expired answer that
    ///         moved something. Nothing is applied, and the compliance blocks `chainKey`.
    event ReceiptRefused(bytes32 indexed ticketId, bytes32 indexed chainKey, uint256 amount, bytes32 askBlockHash);
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
