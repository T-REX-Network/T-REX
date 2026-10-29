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
    ///  shapes changed while no token or Lite was live, so the version stayed 1. Once anything is live, a change to
    ///  a body's shape bumps it, so a peer on the old shape refuses the new one instead of decoding it wrong.
    uint8 internal constant VERSION = 1;

    /// @dev The ERC-7930 chain type of every EVM chain, where CREATE3 puts a Lite at its token's own address.
    bytes2 internal constant EVM_CHAIN_TYPE = 0x0000;

    /// @dev EIP-712 type hash of `ComplianceValidation`:
    ///  keccak256("ComplianceValidation(uint256 validationId,bytes from,bytes to,bytes spender,uint256 amountMin,
    ///  uint256 amountMax,address token,uint64 expiry,uint64 reconciliationWindow)")
    bytes32 internal constant COMPLIANCE_VALIDATION_TYPEHASH =
        0x0b9e295f943ccd7dad6f3ca3f907365ba5866f07431e165136759414e1e5f9f6;

    /// @dev Body of a `COMPLIANCE_VALIDATION`: the reference chain's authorization for one movement, the only thing
    /// a satellite executes a transfer against.
    /// Validations expire; settlements never do.
    struct ComplianceValidation {
        /// Unique per compliance contract, single-use: consumed on the satellite, keys the slot on T-REX.
        uint256 validationId;
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
        uint256 validationId;
        /// ERC-7930; empty on the mint leg.
        bytes from;
        /// ERC-7930; empty on the burn leg.
        bytes to;
        uint256 amount;
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

    /// @dev EIP-712 `hashStruct` of a validation, without a domain: an identifier, not something to sign.
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
                validation.token,
                validation.expiry,
                validation.reconciliationWindow
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
