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

import { MessageTypesLib } from "./MessageTypesLib.sol";

/// @dev Errors of the ERC-3643 standard surface are declared canonically in
///  {ERC3643ErrorsLib}, inside the standard layer, because the standard bases may not import from the
///  T-REX layer (issue #65). The names below are re-declared here for the T-REX layer and for tests.
///  Solidity identifies errors by selector, so a re-declaration with the same signature is the same
///  error on the wire; `forge lint` reporting some of them as unused only means no T-REX-layer contract
///  raises them any more, not that they are unreachable.
library ErrorsLib {

    // Common Errors
    error ZeroAddress();
    error ZeroValue();
    error ArraySizeLimited(uint256 maxSize);
    error ArrayLengthMismatch();
    error InvalidImplementationAuthority();
    /// @dev The ERC-173 `transferOwnership` is refused: the owner is the AccessManager, and it changes only through
    ///      `AccessManager.updateAuthority`, which applies the target's admin delay.
    error UseUpdateAuthority();

    // Token Errors
    error AmountAboveFrozenTokens(uint256 amount, uint256 maxAmount);
    error ComplianceNotFollowed();
    error DecimalsOutOfRange(uint256 decimals);
    error EmptyString();
    error FrozenWallet(address user);
    error ComplianceAlreadyBoundToToken();
    error TokenCirculating();
    error TicketsStillReserved();
    error InvalidCompliance();
    error InvalidIdentityRegistry();
    error NoTokenToRecover();
    error NotLinkedIdentity(address from, address caller);
    error RecoveryNotPossible();
    error SameWalletRecovery();
    error SpenderNotAllowed(address spender, address from, address to, uint256 value);
    error UnverifiedIdentity();
    /// @dev Only a wallet on another chain can hold a bridged position; this envelope designates this chain.
    error NotASatelliteWallet(bytes wallet);
    /// @dev Only the bound compliance applies a settlement to the ledger.
    error OnlyBoundCompliance();
    /// @dev The bridged position on the wallet is smaller than the amount to move out of it.
    error InsufficientBridgedBalance(bytes wallet, uint256 balance, uint256 needed);
    /// @dev A bring home moves location, never ownership: the home wallet and the away wallet must resolve to one
    ///  identity, and that identity must exist.
    error WalletsNotLinked(address nativeWallet, bytes wallet);
    /// @dev The away wallet already has a bring home open; one at a time.
    error BringHomeAlreadyOpen(bytes32 walletKey, bytes32 ticketId);
    /// @dev The chain's peer or receipt route changed since the half was first sent; a send never retargets.
    error PeerChanged(bytes32 chainKey);
    /// @dev The ticket already holds money on hold; a move puts its money on hold once.
    error TransitAlreadyHeld(bytes32 ticketId);

    // ModularCompliance Errors
    error AddressNotATokenBoundToComplianceContract();
    error ComplianceNotSuitableForBindingToModule(address module);
    error MaxModulesReached(uint256 maxValue);
    error ModuleAlreadyBound();
    /// @dev A module names no type at all, so the compliance would never call it.
    error ModuleHasNoType();
    /// @dev A module names the same type twice.
    error DuplicateModuleType(uint8 moduleType);
    /// @dev An upgrade would change the types a module names, which every bound compliance read at binding.
    error ModuleTypesChanged();
    error ModuleNotBound();
    error TokenNotBound();

    // Module Errors
    error ComplianceNotBound();
    error ComplianceAlreadyBound();
    error ModuleStillBound();
    error OnlyBoundComplianceCanCall();
    error OnlyComplianceContractCanCall();
    error SpenderAlreadyAllowed(bytes spender);
    error SpenderNotListed(bytes spender);
    error ApprovalIdAlreadyUsed(bytes32 approvalId);
    error OneApprovalModuleOnly();
    error ApproversNotSet();
    error NotAnApprover(address caller);
    error NotTheNextApprover(address caller, address expected);
    error UnknownApprovalRequest(bytes32 ticketId);
    error ApproversChanged(bytes32 ticketId);
    error NotFullyApproved(bytes32 ticketId);
    error AlreadyFullyApproved(bytes32 ticketId);
    error ExpiryInPast(uint64 expiry);
    error TransferNotApproved(address from, address to, uint256 amount);

    // TREXFactory Errors
    error AuthorityMismatch();
    error StorageAuthorityMismatch(address identityRegistryStorage, address expected, address actual);
    error AccessManagerNotAContract(address accessManager);
    error InvalidAccessManagerAdmin();
    error InvalidClaimPattern();
    error InvalidCompliancePattern();
    error MaxClaimIssuersReached(uint256 max);
    /// @dev A token's ONCHAINID, supplied at deploy or set later, must be the identity the IdentityFactory binds
    ///  to the token's address. A new identity registry is held to the same rule, on its own IdentityFactory,
    ///  for the ONCHAINID the token already has.
    error TokenIdentityNotBound(address token, address suppliedIdentity);
    /// @dev Only a MANAGEMENT key of a supplied ONCHAINID may deploy a suite with it.
    error TokenIdentityNotManagedByCaller(address suppliedIdentity, address caller);
    error TokenAlreadyDeployed();
    error IsolatedSuiteCannotReuseIRS();

    // ClaimTopicsRegistry Errors
    error ClaimTopicAlreadyExists();
    error InvalidIdentityType();

    // IdentityRegistry Errors
    error EligibilityChecksDisabledAlready();
    error EligibilityChecksEnabledAlready();

    // IdentityRegistryStorage Errors
    error AddressAlreadyStored();
    error AddressNotYetStored();
    error IdentityRegistryNotStored();
    error MaxIRByIRSReached(uint256 max);
    /// @dev The registry resolves through another IdentityFactory than the one the storage was initialised with.
    error IdentityFactoryMismatch(address expected, address actual);
    // Same names as the ONCHAINID IdentityFactory errors, but keyed by address.
    /// @dev The wallet is bound to another identity.
    error WalletBoundToAnotherIdentity(address wallet, address boundIdentity);
    /// @dev The wallet is already bound to this identity.
    error WalletAlreadyLinkedToIdentity(address wallet);
    /// @dev The wallet was revoked and can never be bound again.
    error WalletAlreadyRevoked(address wallet);
    /// @dev The wallet is not active.
    error WalletNotActive(address wallet);

    // AccessManagerSetupLib Errors
    error SuiteDeployerCannotConfigureFactory();
    error PlatformRoleCannotBePublic();

    // RolesLib Errors
    error InvalidDomain();

    // TREXAccessManager Errors
    error DomainNotFound(uint32 domainId);
    /// @dev `target` is already set up in `domainId`: a token is set up once, and a storage, a registry or a
    ///      compliance already in a domain cannot be used by a suite of another one.
    error SuiteAlreadySetUp(address target, uint32 domainId);

    // TrustedIssuersRegistry Errors
    error ClaimTopicsCannotBeEmpty();
    error MaxClaimTopicsReached(uint256 max);
    error MaxTrustedIssuersReached(uint256 max);
    error NotATrustedIssuer();
    error TrustedClaimTopicsCannotBeEmpty();
    error TrustedIssuerAlreadyExists();

    // TREXImplementationAuthority Errors
    error EmptyImplementations();
    error UnknownVersion();
    error VersionAlreadyPublished();
    error VersionNotNewer();

    // TREXRegistry Errors
    error Deprecated();

    // Tickets Errors
    /// @dev A `SPENDER` module refused the spender named on the requested validation.
    error ValidationSpenderRefused(bytes spender);
    /// @dev The window over which asks are counted must be positive.
    error ZeroDuration();
    /// @dev The token is paused: no validation is issued, approved into issuance or resent until it is unpaused,
    ///  none whose receipt may be in flight is cancelled, and a waiting receipt is applied only once it is unpaused.
    error TokenPaused();
    /// @dev Issuance needs a validity window; none was configured.
    error ValidityWindowNotSet();
    /// @dev Issuance toward this chain needs its reconciliation window; none was configured.
    error WaitingTimeNotSet(bytes32 chainKey);
    /// @dev The requested range is inverted.
    error InvalidRequestedRange(uint256 requestedMin, uint256 requestedMax);
    /// @dev The balance cap, the modules or the clamp left no amount to authorize.
    error EmptyValidationRange(uint256 min, uint256 max);
    /// @dev The caller is neither the identity `from` is linked to nor authorised by the AccessManager.
    error NotAuthorizedForWallet(address caller, bytes wallet);
    /// @dev `from` has no identity, or `to` is not eligible for new activity.
    error UnverifiedWallet(bytes wallet);
    /// @dev Both wallets are home wallets: that is a plain transfer, not a move between chains.
    error NotACrossChainMove();
    /// @dev Only a validation stored `WaitingForApproval` can be answered; `status` is the one found instead.
    error ValidationNotAwaitingApproval(bytes32 ticketId, uint8 status);
    /// @dev Only the bound `APPROVAL` module answers a validation awaiting approval.
    error NotTheApprovalModule(address caller);
    /// @dev A ticket can be sent again while it is stored `Open`; `status` is the `TicketStatus` found instead.
    error ValidationNotResendable(bytes32 ticketId, uint8 status);
    /// @dev The approver answered at or after `validUntil`, past which no away token may execute.
    error ValidationExpired(bytes32 ticketId, uint64 deadline);
    /// @dev `chainKey` is not the sender's chain, the only one a ticket goes to.
    error ChainNotPartOfValidation(bytes32 ticketId, bytes32 chainKey);
    /// @dev The supplied `to` or `spender` is not the one the ticket was asked with: the ticket recorded under this
    ///  id keeps the key of the first and the second itself.
    error ValidationBodyMismatch(bytes32 ticketId);
    /// @dev The id was never issued by this compliance.
    error UnknownTicket(bytes32 ticketId);
    /// @dev The id of the whole request is already recorded: the same request, salt included, was asked twice.
    error TicketAlreadyWritten(bytes32 ticketId);
    /// @dev No receipt waits under this half with the body given, or its ticket is not sent yet.
    error NoWaitingReceipt(bytes32 halfKey);
    /// @dev A waiting receipt is refused by hand only while its away chain is blocked.
    error AwayChainNotBlocked(bytes32 chainKey);
    /// @dev A receipt `chainKey` sent for this ticket waits here: it is applied first, so that the ticket is not
    ///  cancelled over a receipt this chain already holds.
    error ApplyWaitingReceiptFirst(bytes32 ticketId, bytes32 chainKey);
    /// @dev Only a stored `Open` validation can be discarded; `status` is the `TicketStatus` found instead.
    error TicketNotCancellable(bytes32 ticketId, uint8 status);
    /// @dev The ticket may not be cancelled yet: no ask for its receipt has gone unanswered for one waiting time.
    ///  `dueAt` is the earliest the cancel can come, once such an ask is out.
    error CancelNotDue(bytes32 ticketId, uint64 dueAt);
    /// @dev The ticket was already asked for its receipt the most times allowed.
    error NoAsksLeft(bytes32 ticketId);
    /// @dev The next ask for the ticket's receipt, or the next send of its second half, is due only at `dueAt`.
    error SendNotDue(bytes32 ticketId, uint64 dueAt);
    /// @dev The ticket owes no second half now: it holds no money with a destination, or its latest half was sent
    ///  the most times allowed and is waiting for its receipt.
    error SecondHalfNotOwed(bytes32 ticketId);
    /// @dev The ticket's money on hold already had the most new halves allowed; a human ends it.
    error NoNewHalfLeft(bytes32 ticketId);
    /// @dev The money on hold under `laterTicketId` still carries uncounted credit of the one under `ticketId`: the
    ///  earlier one is not cancelled before the later one gives it back, and the later one is not taken before the
    ///  earlier one is.
    error LaterHoldStillCarries(bytes32 ticketId, bytes32 laterTicketId);
    /// @dev The receipt held under `ticketId` moved an amount the ask mined again does not allow, or echoed a maximum
    ///  above what was asked or above the away chain's per-ticket cap: the ask does not take it.
    error HeldReceiptBreaksItsTerms(bytes32 ticketId);
    /// @dev Less gas is left than a second half's send needs: the whole delivery reverts and stays deliverable.
    error NotEnoughGasForTheSecondHalf(uint256 left, uint256 needed);
    /// @dev The waiting time `duration` of `chainKey` is not above `mustBeAbove`: one hour less a second, or a floor
    ///  measured for that chain.
    error WaitingTimeTooShort(bytes32 chainKey, uint64 duration, uint64 mustBeAbove);
    /// @dev A validity window must be above the floor measured for every away chain and at most the longest allowed.
    error ValidityWindowOutOfRange(uint64 duration, uint64 mustBeAbove, uint64 mustBeAtMost);
    /// @dev New asks are paused for the whole token; receipts still land.
    error AsksPaused();
    /// @dev The identity asked as many times as it may in the current window.
    error AskLimitReached(address identity);
    /// @dev The identity already has as many tickets waiting for approval or open as it may.
    error TooManyOpenTickets(address identity);
    /// @dev The asked maximum is below the smallest amount one may ask to move.
    error BelowSmallestAmount(uint256 requestedMax, uint256 smallestAmount);
    /// @dev The asked maximum is above what the sending wallet has free: the id is built from the asked maximum, so it
    ///  is refused rather than narrowed.
    error RequestAboveBalance(bytes wallet, uint256 free, uint256 requestedMax);
    /// @dev The per-ticket cap toward `chainKey` is lowered while a ticket sent under the higher cap may still be
    ///  executed: an honest receipt of it would then block that away chain. Allowed from `allowedAt`.
    error PerTicketCapLoweredTooEarly(bytes32 chainKey, uint64 allowedAt);
    // Interop Errors
    error NonCanonicalInteroperableAddress(bytes envelope);
    error AwayChainBlocked(bytes32 chainKey);
    /// @dev The route or peer of `chainKey` changed less than four waiting times ago: a change now would drop the
    ///  former pair while receipts sent on it may still be on their way. Allowed from `allowedAt`.
    error RouteChangedTooRecently(bytes32 chainKey, uint64 allowedAt);
    /// @dev The peer of `chainKey` was replaced as hostile: asks, ticket sends and cancels for it wait until `endsAt`.
    error HostileChangeNotOver(bytes32 chainKey, uint64 endsAt);
    error ChainNotOpen(bytes32 chainKey);
    error ChainNotRegistered(bytes32 chainKey);
    error BridgeNotOnRoute(address gateway, bytes32 chainKey);
    error BridgeNotTrusted(address gateway);
    /// @dev `bridge` is not recorded as a receipt bridge, the only kind a receipt route may use.
    error NotAReceiptBridge(address bridge);
    /// @dev `bridge` is not recorded as a ticket bridge, the only kind a ticket route may use.
    error NotATicketBridge(address bridge);
    /// @dev `bridge` was distrusted, and a distrusted bridge is never trusted again.
    error BridgeDistrusted(address bridge);
    /// @dev `bridge` already has its one record; a bridge that changes is a new bridge.
    error BridgeAlreadyRecorded(address bridge);
    /// @dev The receiving policy of `bridge` admits messages from `chainKey` before that chain's full finality.
    error ReceiptBridgeNotFullFinality(address bridge, bytes32 chainKey);
    error InvalidChainReference(bytes2 chainType, bytes chainReference);
    error InvalidPeer(bytes peer);
    error MessageAlreadyReceived(address gateway, bytes32 receiveId);
    error MessageTypeNotInbound(MessageTypesLib.Message messageType);
    error PeerChainMismatch(bytes32 chainKey, bytes32 peerChainKey);
    error SenderNotCompliance(address sender);
    error SenderNotPeer(bytes32 chainKey, bytes sender);
    error UnsupportedMessageVersion(uint8 messageVersion);

}
