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

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ErrorsLib } from "./ErrorsLib.sol";

/**
 * @title MessageTypesLib
 * @dev The protocol's ERC-7786 message surface: the five types that cross the interop boundary, the
 * bodies they carry, and the envelope that wraps them.
 */
library MessageTypesLib {

    /// @dev The five types that cross the interop boundary, numbered from zero as their wire codes.
    /// Appending a member is the only backward-compatible way to grow the surface.
    enum Message {
        /// Outbound. A `ComplianceValidation` issued on the reference chain for a satellite to execute.
        COMPLIANCE_VALIDATION,
        /// Outbound. A delegation-out instruction to mint on a satellite. Resent unchanged under its `delegationId`;
        /// the Lite mints once per id.
        MINT_INSTRUCTION,
        /// Outbound. A forced-recall instruction to burn on a satellite. Answered by a `BURN_PROOF` under its id.
        RECALL_INSTRUCTION,
        /// Inbound. A satellite reporting that a validation's leg executed.
        SETTLEMENT_NOTIFICATION,
        /// Inbound. A satellite's proof that it burned a position, so a recall can credit the holder.
        BURN_PROOF
    }

    /// @dev The envelope version this library serves. A payload carrying any other version is refused. The body
    ///  shapes changed while no token or Lite was live (the id became salt-derived and the settlement gained the
    ///  hash of the body executed), so the version stayed 1. Once anything is live, a change to a body's shape bumps
    ///  it, so a peer on the old shape refuses the new one instead of decoding it wrong.
    uint8 internal constant VERSION = 1;

    /// @dev The ERC-7930 chain type of every EVM chain, where CREATE3 puts a Lite at its token's own address.
    bytes2 internal constant EVM_CHAIN_TYPE = 0x0000;

    /// @dev EIP-712 type hash of the terms of a `ComplianceValidation`, see {hashValidation}:
    ///  keccak256("ComplianceValidation(bytes32 validationId,bytes from,bytes to,bytes spender,uint256 amountMin,
    ///  uint256 amountMax,address token)")
    bytes32 internal constant COMPLIANCE_VALIDATION_TYPEHASH =
        0xafd18733126d2336f2b9ca999b9c8ad036ae2ed6021708f89e163f1c7fdce926;

    /// @dev Body of a `COMPLIANCE_VALIDATION`: the reference chain's authorization for one movement, the only thing
    /// a satellite executes a transfer against.
    /// Validations expire; settlements never do.
    struct ComplianceValidation {
        /// `keccak256(abi.encode(canonicalKey(from), salt))`, the salt supplied by the requester: a function of the
        /// request and never of the reference chain's ordering or clock, so a reorg that re-includes or drops the
        /// issuance leaves the id the satellite executed under unchanged. Single-use: consumed on the satellite, keys
        /// the record on T-REX.
        bytes32 validationId;
        /// The requester's nonce the id was derived from. Carried so that the satellite chain, where the body is
        /// final, holds what it takes to send the request again should a reorg drop its issuance: an agent reads
        /// it off the Lite and re-issues the same id. Not part of {hashValidation}: the id commits to it.
        bytes32 salt;
        /// ERC-7930 sender. Its chain reference against `to`'s decides same-chain transfer or burn-and-mint.
        bytes from;
        /// ERC-7930 recipient.
        bytes to;
        /// ERC-7930 address allowed to execute through `transferFrom`; empty means `from` alone.
        bytes spender;
        /// Inclusive lower bound, caller-proposed and engine-narrowed.
        uint256 amountMin;
        /// Inclusive upper bound, caller-proposed, engine-narrowed, capped at `from`'s recorded balance so no
        /// settlement carries an amount the ledger cannot absorb, and none is ever rejected to protect it. Tokens
        /// invented on a satellite obtain no validation only if the Lite consumes one per transfer and the bridged
        /// ledger is correct.
        uint256 amountMax;
        /// The asset's reference-chain address, its canonical identifier everywhere.
        address token;
        /// Absolute timestamp: the satellite executes strictly before it.
        uint64 expiry;
        /// Seconds T-REX keeps the slot reserved past `expiry` for the reconciliation.
        uint64 reconciliationWindow;
    }

    /// @dev Body of a `SETTLEMENT_NOTIFICATION`: a satellite reporting that one leg of a validation executed.
    struct SettlementNotification {
        bytes32 validationId;
        /// ERC-7930; empty on the mint leg.
        bytes from;
        /// ERC-7930; empty on the burn leg.
        bytes to;
        uint256 amount;
        /// {hashValidation} of the body the Lite executed under. Evidence, not a gate: the reference chain judges the
        /// leg on its wallets and amount, and reads the hash to tell a body it never canonically issued (a reorg
        /// orphaned it) from a Lite that broke a rule on the body it did issue.
        bytes32 hash;
    }

    /// @dev Body of a `MINT_INSTRUCTION`: the reference chain already burned `amount` of `holder`'s native balance
    /// and credited `toWallet`'s bridged position, so the satellite mints the same amount there, once per
    /// `delegationId`. A resend carries the same body byte for byte.
    struct MintInstruction {
        /// Unique per token, sequential from 1: the Lite mints at most once per id.
        uint256 delegationId;
        /// ERC-7930 satellite wallet to mint to, linked to the same identity as `holder`.
        bytes toWallet;
        uint256 amount;
        /// Reference-chain wallet the tokens left. Informational for the satellite.
        address holder;
    }

    /// @dev Body of a `RECALL_INSTRUCTION`: an order to burn up to `amount` of `wallet` on the satellite and answer
    /// with a `BurnProof` under the same `recallId`. A resend carries the same body byte for byte.
    struct RecallInstruction {
        /// Unique per token, sequential from 1: keys the pending recall the proof must answer.
        uint256 recallId;
        /// ERC-7930 satellite wallet to burn.
        bytes wallet;
        /// Upper bound: the satellite may burn less when a validation moved part of the position first.
        uint256 amount;
        /// Reference-chain wallet the token will credit. Informational for the satellite.
        address nativeWallet;
    }

    /// @dev Body of a `BURN_PROOF`: a satellite's proof that it burned a position under a recall instruction. The
    /// token credits the native wallet the instruction recorded, never one the proof could name.
    struct BurnProof {
        /// The recall this proof answers.
        uint256 recallId;
        /// ERC-7930 wallet the satellite burned. Must be the instructed one.
        bytes burnedWallet;
        /// What was burned: at most the instructed amount, possibly zero.
        uint256 amount;
    }

    /// @dev Wraps `body` in the envelope.
    function encode(Message messageType, bytes memory body) internal pure returns (bytes memory) {
        return abi.encode(messageType, VERSION, body);
    }

    /// @dev Unwraps an envelope into its type and its untouched body.
    ///
    /// The ABI decoder validates the type against `Message` before the body is read, so an undefined
    /// type reverts without data and never reaches a handler.
    function decode(bytes memory payload) internal pure returns (Message messageType, bytes memory body) {
        uint8 messageVersion;
        (messageType, messageVersion, body) = abi.decode(payload, (Message, uint8, bytes));

        require(messageVersion == VERSION, ErrorsLib.UnsupportedMessageVersion(messageVersion));
    }

    /// @dev EIP-712 `hashStruct` of a validation's terms, without a domain: a commitment, not something to sign.
    ///  The terms are the id, the wallets, the spender, the range and the token. `expiry` and `reconciliationWindow`
    ///  are left out on purpose: both are read off the issuing block's clock, so a body re-issued after a reorg
    ///  dropped the first issuance would otherwise hash differently for the same movement, and the hash could no
    ///  longer say whether the satellite executed the terms this chain issued.
    function hashValidation(ComplianceValidation memory validation) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                COMPLIANCE_VALIDATION_TYPEHASH,
                validation.validationId,
                keccak256(validation.from),
                keccak256(validation.to),
                keccak256(validation.spender),
                validation.amountMin,
                validation.amountMax,
                validation.token
            )
        );
    }

    /// @dev Wraps a compliance validation in the envelope, as the compliance does before dispatching a leg.
    function encodeValidation(ComplianceValidation memory validation) internal pure returns (bytes memory) {
        return abi.encode(Message.COMPLIANCE_VALIDATION, VERSION, abi.encode(validation));
    }

    /// @dev Unwraps a `COMPLIANCE_VALIDATION` body. Reverts on a body that is not one.
    function decodeValidation(bytes memory body) internal pure returns (ComplianceValidation memory) {
        return abi.decode(body, (ComplianceValidation));
    }

    /// @dev Wraps a settlement notification in the envelope, as a satellite's Lite does before sending.
    function encodeSettlement(SettlementNotification memory notification) internal pure returns (bytes memory) {
        return abi.encode(Message.SETTLEMENT_NOTIFICATION, VERSION, abi.encode(notification));
    }

    /// @dev Unwraps a `SETTLEMENT_NOTIFICATION` body. Reverts on a body that is not one.
    function decodeSettlement(bytes memory body) internal pure returns (SettlementNotification memory) {
        return abi.decode(body, (SettlementNotification));
    }

    /// @dev Unwraps a `MINT_INSTRUCTION` body, as a satellite's Lite does. Reverts on a body that is not one.
    function decodeMintInstruction(bytes memory body) internal pure returns (MintInstruction memory) {
        return abi.decode(body, (MintInstruction));
    }

    /// @dev Unwraps a `RECALL_INSTRUCTION` body, as a satellite's Lite does. Reverts on a body that is not one.
    function decodeRecallInstruction(bytes memory body) internal pure returns (RecallInstruction memory) {
        return abi.decode(body, (RecallInstruction));
    }

    /// @dev Wraps a burn proof in the envelope, as a satellite's Lite does before sending.
    function encodeBurnProof(BurnProof memory proof) internal pure returns (bytes memory) {
        return abi.encode(Message.BURN_PROOF, VERSION, abi.encode(proof));
    }

    /// @dev Unwraps a `BURN_PROOF` body. Reverts on a body that is not one.
    function decodeBurnProof(bytes memory body) internal pure returns (BurnProof memory) {
        return abi.decode(body, (BurnProof));
    }

    /// @dev The per-chain key every route, peer and per-chain setting is stored under.
    ///
    /// Hashes ERC-7930's canonical chain identifier, so one key covers a chain whatever address it
    /// is paired with.
    function chainKey(bytes2 chainType, bytes memory chainReference) internal pure returns (bytes32) {
        return keccak256(InteroperableAddress.formatV1(chainType, chainReference, ""));
    }

}
