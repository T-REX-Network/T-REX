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

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";

import { IModule } from "../compliance/modular/modules/IModule.sol";
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
    /// @notice Emitted when a burn proof answers a recall never issued, or differs from the proof that settled it.
    ///  Nothing is applied. As on a replayed settlement, the token pauses its inbound from `originChainKey` when
    ///  the recall is one it issued, and pauses itself when it is not, since an unknown id may as well mean the
    ///  token's own records are out of step, see {ISettlementHandler-Verdict}.
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
    event ReturnedInTransit(bytes32 indexed walletKey, bytes32 indexed validationId, bytes wallet, uint256 amount);

    /// The keeper gave up on a pair whose other leg never arrived. `returnedAmount` went back to the wallet it
    /// was burned from, or is zero when it was the mint leg that landed and nothing here could be returned.
    event ValidationResolved(bytes32 indexed validationId, uint256 returnedAmount);

    event HeldInTransit(bytes32 indexed fromKey, bytes32 indexed validationId, bytes fromWallet, uint256 amount);
    /// @notice Emitted on a settled movement between two satellite wallets, under the validation it consumed.
    event BridgedTransfer(
        bytes32 indexed fromKey,
        bytes32 indexed toKey,
        bytes32 indexed validationId,
        bytes from,
        bytes to,
        uint256 amount
    );
    /// @notice Emitted on a settled movement leaving a satellite wallet for a native one, under the validation it
    ///  consumed. Ownership moves between identities, unlike {Recalled}.
    event SettledToNative(
        bytes32 indexed fromKey, address indexed to, bytes32 indexed validationId, bytes fromWallet, uint256 amount
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

    event TrustedGatewaySet(address indexed gateway, bool trusted);

    // TREXMessaging Events

    /// @notice Emitted by the factory when its registry pointer moves, and by a token once, at deployment.
    event TrustedGatewayRegistrySet(address trustedGatewayRegistry);
    /// @notice Emitted the first time a token learns the ERC-7930 prefix behind a `chainKey`.
    event ChainRegistered(bytes32 indexed chainKey, bytes2 chainType, bytes chainReference);
    event RouteSet(bytes32 indexed chainKey, address indexed gateway);
    event PeerSet(bytes32 indexed chainKey, bytes peer);
    /// @notice Emitted when a validation's leg toward `chainKey` is pinned to the gateway that carried it.
    event ValidationRoutePinned(bytes32 indexed validationId, bytes32 indexed chainKey, address gateway);
    event ProtocolMessageSent(MessageTypesLib.Message indexed messageType, bytes32 indexed chainKey, bytes32 sendId);
    event ProtocolMessageReceived(
        MessageTypesLib.Message indexed messageType, bytes32 indexed chainKey, bytes32 receiveId
    );
    /// @notice Emitted by the token when an attributed burn proof reaches its recall path, before it is judged.
    event BurnProofReceived(
        bytes32 indexed originChainKey, uint256 indexed recallId, bytes burnedWallet, uint256 amount
    );
    /// @notice Emitted when the token stops taking messages from `chainKey`: by the pauser, or on a message that
    ///  chain sent for something already accounted for. Deliveries from that chain revert and stay deliverable.
    event InboundPaused(bytes32 indexed chainKey);
    /// @notice Emitted when the pauser takes messages from `chainKey` again.
    event InboundUnpaused(bytes32 indexed chainKey);

    // ModularCompliance Interop Events

    /// @notice Emitted by the compliance when the token hands it an attributed settlement notification.
    event SettlementNotified(
        bytes32 indexed originChainKey, bytes32 indexed validationId, bytes from, bytes to, uint256 amount
    );

    // TransferValidation Events
    event DefaultValidityWindowSet(uint64 duration);
    event ReconciliationWindowSet(bytes32 indexed chainKey, uint64 duration);
    event ValidationIssuancePaused(bytes32 indexed chainKey);
    event ValidationIssuanceUnpaused(bytes32 indexed chainKey);
    /// @notice Emitted on issuance with the full envelopes and the final bounds, so indexers need no reverse table.
    event TransferValidationIssued(
        bytes32 indexed validationId,
        bytes from,
        bytes to,
        bytes spender,
        uint256 amountMin,
        uint256 amountMax,
        uint64 expiry,
        uint64 reconciliationWindow,
        bytes32 salt
    );
    /// @notice Warning: a reconciliation of `validationId` arrived from `chainKey` after its release deadline.
    ///         The settlement is recorded regardless. Issuance for that chain pauses only when the recorded state
    ///         breaches a rule; otherwise this warning is the whole record.
    event LateReconciliation(bytes32 indexed validationId, bytes32 indexed chainKey);
    /// @notice Emitted when the keeper discards an expired validation and its slots are released.
    event ValidationDiscarded(bytes32 indexed validationId);
    /// @notice Emitted when a validation is recorded and reserved while an `APPROVAL` module decides it.
    event TransferValidationAwaitingApproval(
        bytes32 indexed validationId,
        bytes from,
        bytes to,
        bytes spender,
        uint256 amountMin,
        uint256 amountMax,
        uint64 deadline
    );
    /// @notice Emitted when a validation awaiting approval is refused, or left unanswered past its deadline, and
    ///         its reservation released.
    event ValidationApprovalRefused(bytes32 indexed validationId);
    /// @notice Emitted when the leg of an issued validation toward `chainKey` is sent again, byte for byte.
    event ValidationResent(bytes32 indexed validationId, bytes32 indexed chainKey);
    /// @notice Emitted when the first of the two legs of a cross-chain validation was consumed, whichever it was:
    ///         the validation is pinned and can no longer be discarded.
    event ValidationLegConfirmed(bytes32 indexed validationId, bytes32 indexed chainKey, uint256 amount);

    /// The registry now names another identity for a wallet that holds tokens, so its balance followed it: what
    /// the previous identity's position counted for this wallet is now the new one's.
    event WalletOwnerChanged(
        address indexed wallet, address indexed previousIdentity, address indexed identity, uint256 amount
    );

    /// @notice Emitted when every expected leg of a validation was received: slots committed, ledger updated.
    ///         `chainKey` is the chain of the leg that completed it.
    event ValidationSettled(bytes32 indexed validationId, bytes32 indexed chainKey, uint256 amount);
    /// @notice Emergency: a trusted gateway delivered a leg already accounted for, or a second leg for an id
    ///         whose first one is parked. Nothing is applied and the token pauses its inbound from `chainKey`,
    ///         lifted by the pauser after an investigation.
    event ReplayedSettlement(bytes32 indexed validationId, bytes32 indexed chainKey);
    /// @notice A leg arrived from `chainKey` for an id with no issued body: the satellite executed a validation
    ///         this chain never sent, which a reorg that dropped the issuance explains as well as a hostile Lite.
    ///         The leg is kept under its id and the token pauses its inbound from `chainKey`. Once the request is
    ///         sent again with the same salt, `settleParkedLeg` settles it.
    event SettlementParked(bytes32 indexed validationId, bytes32 indexed chainKey, uint256 amount, bytes32 hash);
    /// @notice A parked leg from `chainKey` was settled, once its validation was issued.
    event ParkedLegSettled(bytes32 indexed validationId, bytes32 indexed chainKey);
    /// @notice A leg from `chainKey` carries the issued hash but wallets or an amount outside the issued terms:
    ///         the Lite broke a rule on the body this chain issued. Nothing is applied, the validation stands,
    ///         and the token pauses its inbound from `chainKey`.
    event SettlementRejected(bytes32 indexed validationId, bytes32 indexed chainKey, uint256 amount, bytes32 hash);
    /// @notice A leg from `chainKey` fails the issued terms and carries another hash: the satellite executed a body
    ///         this chain never canonically issued, one a reorg orphaned. Nothing is applied and the token pauses
    ///         its inbound from `chainKey`. While no leg had landed yet the validation ends `Orphaned`, its
    ///         reservation released; otherwise it stands and the keeper resolves the pair after the second window.
    event ValidationOrphaned(bytes32 indexed validationId, bytes32 indexed chainKey, uint256 amount, bytes32 hash);
    /// @notice Information: a leg from `chainKey` settled inside the issued terms but carries another hash, so the
    ///         satellite executed a body that differed in something the terms do not cover, or a wider range
    ///         the canonical issuance narrowed, inside which the executed amount still sits.
    event SettlementBodyDiverged(bytes32 indexed validationId, bytes32 indexed chainKey, bytes32 hash);
    // TREXAccessManager Events

    event DomainCreated(uint32 indexed domainId, string name);
    event DomainAssigned(uint32 indexed domainId, address indexed target);

    // TREXImplementationAuthority Events

    event BeaconsDeployed(ITREXImplementationAuthority.SuiteBeacons beacons);
    event VersionPublished(Version version, ITREXImplementationAuthority.SuiteImplementations implementations);
    event SuiteUpgraded(Version version, ITREXImplementationAuthority.SuiteImplementations implementations);

}
