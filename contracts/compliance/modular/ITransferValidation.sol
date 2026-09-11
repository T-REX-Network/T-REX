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
 * @dev The compliance contract's issuance surface for satellite movements: the settings a COMPLIANCE_MANAGER
 * tunes, the per-chain issuance pause, and the views the slot lifecycle reads.
 *
 * A satellite never decides compliance. It executes a transfer only against a `ComplianceValidation` the
 * reference chain issued for that exact transfer; this interface is where that object comes from.
 */
interface ITransferValidation {

    /// @dev What the compliance keeps of an issued validation, keyed by its id, for the slot lifecycle.
    struct ValidationRecord {
        /// EIP-712 struct hash of the issued `ComplianceValidation`, the identifier the satellite consumes.
        bytes32 hash;
        /// Final inclusive lower bound, so a settlement's executed amount can be classified.
        uint256 amountMin;
        /// Final inclusive upper bound.
        uint256 amountMax;
        /// The satellite's hard deadline: no execution at or after it.
        uint64 expiry;
        /// `expiry + reconciliationWindow`: past it, the slot may be released and the validation discarded.
        uint64 releaseAt;
        /// `keccak256(chainType, chainReference)` of `from`'s chain; the reference chain's own key for a native wallet.
        bytes32 fromChainKey;
        /// Same for `to`'s chain.
        bytes32 toChainKey;
    }

    /// @dev Issues a `ComplianceValidation` for a movement between two ERC-7930 wallets, at least one of them on a
    /// satellite, and dispatches it to the involved Lite deployment or deployments through the token's trusted
    /// gateway. The caller derives the requested range from an amount and a slippage tolerance; only the range is
    /// ever seen here, and it is only ever narrowed.
    ///
    /// The five steps, in order:
    /// 1. Authorization: `from` itself when it lives on this chain, the identity `from` is linked to, or a caller
    ///    the AccessManager authorises for this selector.
    /// 2. Eligibility: `from` must resolve to an identity (revoked included, it owns the position); `to` must pass
    ///    `isWalletVerified`. Two wallets of one identity make a movement that is not a change of ownership: it
    ///    is issued, recorded and reconciled like any other, but no module is consulted.
    /// 3. Bounds: the request intersected with `[0, from's balance on its chain]`, narrowed by every module
    ///    declaring `BOUNDS`, each receiving the running range, then by the clamp. Empty reverts.
    /// 4. Slot reservation, by the slot lifecycle.
    /// 5. Issuance: a fresh id, the record, `TransferValidationIssued`, one leg per involved satellite chain.
    ///
    /// Requirements:
    /// - `requestedMin <= requestedMax`; otherwise reverts with `InvalidRequestedRange`.
    /// - Both envelopes canonical; otherwise reverts with `NonCanonicalInteroperableAddress`.
    /// - At least one side on a satellite; otherwise reverts with `NoSatelliteLeg`.
    /// - The caller authorised over `from`; otherwise reverts with `NotAuthorizedForWallet`.
    /// - A validity window set; otherwise reverts with `ValidityWindowNotSet`.
    /// - No involved satellite chain paused; otherwise reverts with `ValidationIssuancePaused`.
    /// - Every involved satellite chain with a reconciliation window; otherwise `ReconciliationWindowNotSet`.
    /// - `from` bound and `to` eligible; otherwise reverts with `UnverifiedWallet`.
    /// - A non-empty final range; otherwise reverts with `EmptyValidationRange`.
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

    /// @dev Sets the worst-case reconciliation latency of a chain: how long T-REX keeps a slot reserved past
    /// `expiry` for a leg on that chain. Snapshot into each validation at issuance, so a later change never
    /// moves the deadline of an outstanding one.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - `duration` must not be zero; otherwise reverts with `ZeroDuration`.
    ///
    /// Emits `ReconciliationWindowSet`.
    /// @param chainKey `keccak256(chainType, chainReference)` of the chain.
    /// @param duration The window in seconds.
    function setReconciliationWindow(bytes32 chainKey, uint64 duration) external;

    /// @dev Sets an optional global ceiling on `amountMax`, applied after every module narrowed the range.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    ///
    /// Emits `ValidationClampSet`.
    /// @param maxAmount The ceiling, or zero to clear it.
    function setValidationClamp(uint256 maxAmount) external;

    /// @dev Stops issuing validations that involve `chainKey`, on either side of the movement. Also triggered
    /// automatically when a reconciliation from that chain arrives late.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - The chain must not already be paused; otherwise reverts with `ValidationIssuancePaused`.
    ///
    /// Emits `ValidationIssuancePaused`.
    /// @param chainKey `keccak256(chainType, chainReference)` of the chain.
    function pauseValidationIssuance(bytes32 chainKey) external;

    /// @dev Resumes issuance for `chainKey`. The explicit step after the issuer resolved a late-reconciliation
    /// exception, so the exceptional state cannot compound unnoticed.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - The chain must be paused; otherwise reverts with `ValidationIssuanceNotPaused`.
    ///
    /// Emits `ValidationIssuanceUnpaused`.
    /// @param chainKey `keccak256(chainType, chainReference)` of the chain.
    function unpauseValidationIssuance(bytes32 chainKey) external;

    /// @dev The validity window added to the issuance timestamp to compute `expiry`. Zero until set, and
    /// issuance refuses to run while it is zero.
    function defaultValidityWindow() external view returns (uint64);

    /// @dev The reconciliation window configured for `chainKey`, zero when unset.
    /// @param chainKey The chain to look up.
    function reconciliationWindowOf(bytes32 chainKey) external view returns (uint64);

    /// @dev The global ceiling on `amountMax`, zero when none.
    function validationClamp() external view returns (uint256);

    /// @dev Whether issuance is paused for movements involving `chainKey`.
    /// @param chainKey The chain to look up.
    function isIssuancePaused(bytes32 chainKey) external view returns (bool);

    /// @dev The last validation id issued; ids start at 1 and increase by one, so zero is never a valid id.
    function nextValidationId() external view returns (uint256);

    /// @dev The record kept for `validationId`, all zeros when the id was never issued.
    /// @param validationId The validation to look up.
    function validationOf(uint256 validationId) external view returns (ValidationRecord memory);

}
