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

/**
 * @title ITransferValidation
 * @dev The compliance's issuance surface for satellite movements: the two windows a COMPLIANCE_MANAGER tunes, the
 * per-chain issuance pause, the lifecycle of every issued validation and the keeper's discard. A satellite
 * executes a transfer only against a `ComplianceValidation` the reference chain issued for that exact transfer;
 * this is where it comes from. A ceiling on what may be issued is a rule, not a setting: a module answers it
 * from `allowedAmount`.
 */
interface ITransferValidation {

    /// @dev Where a validation stands. Stored transitions: `Pending -> LegConfirmed -> Settled`,
    /// `Pending -> Settled`, `Pending -> Discarded -> LateReconciled`. `Expired` is never written: `statusOf`
    /// derives it for a `Pending` validation past `releaseAt` that the keeper has not discarded yet, since nothing
    /// transitions storage at a timestamp without a transaction.
    enum ValidationStatus {
        /// Issued, pending amounts reserved, waiting for the settlement notification(s).
        Pending,
        /// Cross-chain only: one of the two legs was consumed, whichever it was (`validationOf` says which). Never
        /// discardable and never derived `Expired`: a consumed leg proves irreversible satellite execution, and a
        /// mint stuck between two chains must not roll back the reservation. When the consumed leg is the burn
        /// one, the amount already left the sender's position and waits in transit on the token.
        LegConfirmed,
        /// Every expected leg received, reservation released, positions and ledger updated.
        Settled,
        /// Derived: `Pending` and past `releaseAt`, not yet discarded.
        Expired,
        /// The keeper released the reservation; issuance proceeds as if the validation never happened. A late
        /// first leg of two keeps this status with its flag set.
        Discarded,
        /// Every leg arrived after the discard: applied anyway, `LateReconciliation` emitted per late leg and that
        /// leg's chain paused for issuance when the executed amount breached a rule.
        LateReconciled,
        /// The burn leg landed, the mint leg never came, and the operator gave up on the pair: the burned amount
        /// is back on the wallet it left, the reservation is released, and a mint leg arriving now halts the token.
        Refunded
    }

    /// @dev Everything the compliance keeps of an issued validation, keyed by its id and kept forever: every id
    /// stays classifiable against its stored status for good, which is what makes the emergency responses
    /// possible.
    ///
    /// The fields come in two groups. The first twelve are written once, at issuance, and never change: the
    /// terms of the movement. The last seven are the lifecycle: where the validation stands, what was released,
    /// what a satellite actually executed.
    struct Validation {
        /* ----- Written once, at issuance ----- */

        /// EIP-712 struct hash of the issued `ComplianceValidation`, the identifier the satellite consumes.
        bytes32 hash;
        /// Final inclusive lower bound, so a settlement's executed amount can be classified.
        uint256 amountMin;
        /// Final inclusive upper bound, what the reservation was taken at.
        uint256 amountMax;
        /// The satellite's hard deadline: no execution at or after it.
        uint64 expiry;
        /// `expiry + reconciliationWindow`: past it, the reservation may be released and the validation discarded.
        uint64 releaseAt;
        /// `from`'s satellite chain, keyed as `MessageTypesLib.chainKey` computes it.
        bytes32 fromChainKey;
        /// Same for `to`'s chain; the reference chain's own key for a native wallet.
        bytes32 toChainKey;
        /// `keccak256` of the canonical `from` envelope: what a settlement leg's `from` is matched against, and
        /// the key its pending amount is kept under in the ledger.
        bytes32 fromKey;
        /// Same for `to`.
        bytes32 toKey;
        /// Both sides on distinct satellite chains: two legs are expected, the burn one and the mint one.
        bool twoLegs;
        /// The identity `from` resolved to at issuance: whose pending amount was reserved and whose position
        /// settlement debits.
        address fromIdentity;
        /// Same for `to`. Equal to `fromIdentity` on a relocation between one identity's wallets.
        address toIdentity;

        /* ----- Moved by the lifecycle ----- */

        /// Whether the identities' pending amounts are still outstanding. False when both wallets belong to one
        /// identity, since nothing was reserved for them; cleared by the release, at settlement or at discard,
        /// so a late settlement never releases twice.
        bool pendingReserved;
        /// Same for the sender wallet's pending amount, released earlier on a burn-first leg: the hold already
        /// took the tokens out of the wallet, so the wallet's cap must stop counting them.
        bool walletPendingReserved;
        /// The stored status, `Expired` excluded.
        ValidationStatus status;
        /// The leg originating from `from`'s chain (the burn leg, or the single leg) was consumed.
        bool fromLegConsumed;
        /// The leg originating from `to`'s chain (the mint leg) was consumed. Set together with the other flag
        /// on a single-leg settlement.
        bool toLegConsumed;
        /// Exact amount transferred, written by the first leg and repeated by the second.
        uint256 executedAmount;
        /// On a two-leg validation, the wallet the first consumed leg carried, kept for the second one.
        bytes legWallet;
    }

    /// @dev Issues a `ComplianceValidation` for a movement out of a satellite wallet, toward another satellite
    /// wallet or a native one, and dispatches one leg per involved satellite chain through the token. A sender on
    /// the reference chain is refused: the Lite that executes a validation must physically hold the position it
    /// moves, where a native balance stays free to leave between issuance and settlement. The caller derives the
    /// requested range from an amount and a slippage tolerance; the range is only ever narrowed: capped at `from`'s
    /// bridged position less what is already pending out of it, then at the smallest `allowedAmount` any module
    /// answers (skipped when both wallets belong to one identity).
    ///
    /// Requirements:
    /// - `requestedMin <= requestedMax`; otherwise reverts with `InvalidRequestedRange`.
    /// - Both envelopes, and `spender` when given, canonical; otherwise `NonCanonicalInteroperableAddress`.
    /// - `from` on a satellite chain; otherwise reverts with `SenderNotOnSatellite`.
    /// - The caller is the identity `from` is linked to, or authorised by the AccessManager for this selector;
    ///   otherwise reverts with `NotAuthorizedForWallet`.
    /// - A validity window set, no involved satellite chain paused, and each with a reconciliation window;
    ///   otherwise `ValidityWindowNotSet`, `ValidationIssuancePaused` or `ReconciliationWindowNotSet`.
    /// - `from` bound to an identity (revoked included) and `to` eligible; otherwise `UnverifiedWallet`.
    /// - A non-empty final range with a positive maximum; otherwise `EmptyValidationRange` or `ZeroValue`.
    /// - Every involved chain open on the token; otherwise the token reverts with `ChainNotOpen`.
    ///
    /// Emits `TransferValidationIssued`, then the token's `ValidationRoutePinned` and `ProtocolMessageSent` per leg.
    /// @param from ERC-7930 interoperable address of the sender.
    /// @param to ERC-7930 interoperable address of the recipient.
    /// @param requestedMin Inclusive lower bound the caller proposes.
    /// @param requestedMax Inclusive upper bound the caller proposes.
    /// @param spender ERC-7930 address allowed to execute through `transferFrom`, or empty for `from` alone.
    /// @return validationId The single-use id of the issued validation.
    function requestTransferValidation(
        bytes calldata from,
        bytes calldata to,
        uint256 requestedMin,
        uint256 requestedMax,
        bytes calldata spender
    ) external returns (uint256 validationId);

    /// @dev Sets how long a validation stays executable on the satellite: `expiry` is issuance time plus this.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - `duration` must not be zero; otherwise reverts with `ZeroDuration`.
    ///
    /// Emits `DefaultValidityWindowSet`.
    /// @param duration The validity window in seconds.
    function setDefaultValidityWindow(uint64 duration) external;

    /// @dev Sets how long T-REX keeps a reservation past `expiry` for a leg on that chain. Snapshot at issuance,
    /// so a later change never moves an outstanding deadline.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - `duration` must not be zero; otherwise reverts with `ZeroDuration`.
    ///
    /// Emits `ReconciliationWindowSet`.
    /// @param chainKey The chain, keyed as `MessageTypesLib.chainKey` computes it.
    /// @param duration The window in seconds.
    function setReconciliationWindow(bytes32 chainKey, uint64 duration) external;

    /// @dev Stops or resumes issuing validations involving `chainKey`. A late reconciliation from that chain
    /// whose executed amount breaches a rule pauses it too; lifting the pause is the explicit step after the
    /// exception is resolved. Setting the state it already has changes nothing and emits nothing.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    ///
    /// Emits `ValidationIssuancePaused` or `ValidationIssuanceUnpaused` when the state changes.
    /// @param chainKey The chain, keyed as `MessageTypesLib.chainKey` computes it.
    /// @param paused Whether issuance toward or from the chain is paused.
    function setIssuancePaused(bytes32 chainKey, bool paused) external;

    /// @dev Discards expired validations in a batch: releases their reservations, so the next issuance is
    /// computed as if the pre-approved transfers never happened. Rollback is never automatic; this is the
    /// keeper's job, a restricted role by design: see `RolesLib.VALIDATION_KEEPER` for why it is not
    /// permissionless. The batch is atomic: one refused id reverts the whole call.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - Each id must have been issued; otherwise reverts with `UnknownValidation`.
    /// - Each id must be stored `Pending`; otherwise reverts with `ValidationNotDiscardable`. `LegConfirmed` is
    ///   refused whatever the clock says.
    /// - `block.timestamp` must be past each id's `releaseAt`; otherwise reverts with `ValidationNotReleasable`.
    ///
    /// Emits `ValidationDiscarded` per id.
    /// @param validationIds The validations to discard.
    function discardExpiredValidations(uint256[] calldata validationIds) external;

    /// @dev Gives up on a two-leg validation of which exactly one leg arrived, a second reconciliation window
    ///  past `releaseAt`. When the burn leg is the one that landed, the burned amount goes back to the wallet it
    ///  left and the reservation is released. When the mint leg is, there is nothing on this chain to return:
    ///  the chain that owes the burn stops being issued to instead, and the validation stays as it is.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    ///
    /// Emits `ValidationRefunded`, or `ValidationStuck`.
    function refundValidation(uint256 validationId) external;

    /// @dev The window added to the issuance timestamp to compute `expiry`. Zero until set, which blocks issuance.
    function defaultValidityWindow() external view returns (uint64);

    /// @dev The reconciliation window configured for `chainKey`, zero when unset, which blocks issuance.
    /// @param chainKey The chain to look up.
    function reconciliationWindowOf(bytes32 chainKey) external view returns (uint64);

    /// @dev Whether issuance is paused for movements involving `chainKey`.
    /// @param chainKey The chain to look up.
    function isIssuancePaused(bytes32 chainKey) external view returns (bool);

    /// @dev The last validation id issued; ids start at 1 and increase by one, so zero is never a valid id.
    function lastValidationId() external view returns (uint256);

    /// @dev Everything kept for `validationId`, all zeros when the id was never issued.
    /// @param validationId The validation to look up.
    function validationOf(uint256 validationId) external view returns (Validation memory);

    /// @dev Where `validationId` stands: the stored status, or `Expired` for a stored `Pending` past `releaseAt`.
    ///
    /// Requirements:
    /// - `validationId` must have been issued; otherwise reverts with `UnknownValidation`.
    /// @param validationId The validation to look up.
    function statusOf(uint256 validationId) external view returns (ValidationStatus);

}
