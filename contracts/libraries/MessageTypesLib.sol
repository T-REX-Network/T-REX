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
        /// Outbound. A `TicketMessage` issued on the reference chain for a satellite to execute.
        TICKET,
        /// Outbound. A delegation-out instruction to mint on a satellite. Resent unchanged under its `delegationId`;
        /// the Lite mints once per id.
        MOVE_OUT,
        /// Outbound. A forced-recall instruction to burn on a satellite. Answered by a `BURN_PROOF` under its id.
        BRING_HOME,
        /// Inbound. A satellite reporting that a validation's leg executed.
        RECEIPT,
        /// Inbound. A satellite's proof that it burned a position, so a recall can credit the holder.
        BURN_PROOF
    }

    /// @dev The envelope version this library serves. A payload carrying any other version is refused, so a peer on
    ///  another shape refuses a message instead of decoding it wrong. Version 2: the ticket id is built from the whole
    ///  request, the TICKET and the RECEIPT carry the ask block hash, and the RECEIPT echoes the copy it answers.
    uint8 internal constant VERSION = 2;

    /// @dev The ERC-7930 chain type of every EVM chain, where CREATE3 puts a Lite at its token's own address.
    bytes2 internal constant EVM_CHAIN_TYPE = 0x0000;

    /// @dev Why a receipt says what it says. A receipt of amount zero is either an executed ticket that moved
    ///  nothing or a ticket never executed, and home must tell the two apart.
    enum ReceiptAnswer {
        /// The away token executed the ticket copy it echoes, for `amount`, which may be zero.
        Executed,
        /// The ticket was never executed and its valid until has passed: it never will be. `amount` is zero.
        Expired,
        /// The ticket was never executed and its valid until has not passed: it still may be. `amount` is zero.
        StillOpen
    }

    /// @dev Body of a `TICKET`: home's authorization for one move, the only thing an away token executes a
    /// transfer against. Tickets expire; receipts never do.
    struct TicketMessage {
        /// Built from the whole request, see {TicketLib-ticketIdOf}: a function of what was asked and never of
        /// home's ordering or clock, so the same ask mined again after a reorg keeps its id. Single-use: consumed on
        /// the away chain, keys the record at home.
        bytes32 ticketId;
        /// The requester's nonce the id was built from. Carried so that the away chain, where the ticket is final,
        /// holds what it takes to ask again should a reorg drop the ask: an agent reads it off the away token and
        /// asks again under the same id.
        bytes32 salt;
        /// ERC-7930 sender. Its chain reference against `to`'s decides same-chain transfer or burn-and-mint.
        bytes from;
        /// ERC-7930 recipient.
        bytes to;
        /// ERC-7930 address allowed to execute through `transferFrom`; empty means `from` alone.
        bytes spender;
        /// Inclusive lower bound, as asked.
        uint256 amountMin;
        /// Inclusive upper bound, the asked maximum narrowed by home, capped at `from`'s recorded balance so no
        /// receipt carries an amount the ledger cannot absorb. Tokens invented on an away chain obtain no ticket
        /// only if the away token consumes one per transfer and the away balance is correct.
        uint256 amountMax;
        /// The upper bound as asked, before home narrowed it. Part of the id, so a copy mined again after a reorg
        /// keeps the id even when home narrows it to another `amountMax`.
        uint256 requestedMax;
        /// The asset's home address, its canonical identifier everywhere.
        address token;
        /// Absolute timestamp: the away token executes strictly before it.
        uint64 validUntil;
        /// Names the copy home wrote, see {TicketLib-askBlockHashOf}. Two copies of one ask mined in two blocks share
        /// the id and differ here.
        bytes32 askBlockHash;
    }

    /// @dev Body of a `RECEIPT`: an away chain reporting what it did with one ticket copy.
    struct ReceiptMessage {
        bytes32 ticketId;
        /// ERC-7930; empty on the mint leg.
        bytes from;
        /// ERC-7930; empty on the burn leg.
        bytes to;
        uint256 amount;
        /// The `askBlockHash` of the ticket copy the away token holds: which copy home wrote this receipt answers.
        bytes32 askBlockHash;
        /// The `amountMax` of that copy.
        uint256 seenMax;
        /// The `validUntil` of that copy.
        uint64 seenValidUntil;
        /// Which half of the move the receipt answers: 0 for the away token's execution of a ticket. Read by home
        /// once second halves exist.
        uint8 half;
        /// Why the receipt says what it says, so a zero receipt says why it is zero.
        ReceiptAnswer answer;
    }

    /// @dev Body of a `MOVE_OUT`: the reference chain already burned `amount` of `holder`'s native balance
    /// and credited `toWallet`'s bridged position, so the satellite mints the same amount there, once per
    /// `delegationId`. A resend carries the same body byte for byte.
    struct MoveOutMessage {
        /// Unique per token, sequential from 1: the Lite mints at most once per id.
        uint256 delegationId;
        /// ERC-7930 satellite wallet to mint to, linked to the same identity as `holder`.
        bytes toWallet;
        uint256 amount;
        /// Reference-chain wallet the tokens left. Informational for the satellite.
        address holder;
    }

    /// @dev Body of a `BRING_HOME`: an order to burn up to `amount` of `wallet` on the satellite and answer
    /// with a `BurnProof` under the same `recallId`. A resend carries the same body byte for byte.
    struct BringHomeMessage {
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

    /// @dev Wraps a compliance validation in the envelope, as the compliance does before dispatching a leg.
    function encodeValidation(TicketMessage memory validation) internal pure returns (bytes memory) {
        return abi.encode(Message.TICKET, VERSION, abi.encode(validation));
    }

    /// @dev Unwraps a `TICKET` body. Reverts on a body that is not one.
    function decodeValidation(bytes memory body) internal pure returns (TicketMessage memory) {
        return abi.decode(body, (TicketMessage));
    }

    /// @dev Wraps a settlement notification in the envelope, as a satellite's Lite does before sending.
    function encodeSettlement(ReceiptMessage memory notification) internal pure returns (bytes memory) {
        return abi.encode(Message.RECEIPT, VERSION, abi.encode(notification));
    }

    /// @dev Unwraps a `RECEIPT` body. Reverts on a body that is not one.
    function decodeSettlement(bytes memory body) internal pure returns (ReceiptMessage memory) {
        return abi.decode(body, (ReceiptMessage));
    }

    /// @dev Unwraps a `MOVE_OUT` body, as a satellite's Lite does. Reverts on a body that is not one.
    function decodeMintInstruction(bytes memory body) internal pure returns (MoveOutMessage memory) {
        return abi.decode(body, (MoveOutMessage));
    }

    /// @dev Unwraps a `BRING_HOME` body, as a satellite's Lite does. Reverts on a body that is not one.
    function decodeRecallInstruction(bytes memory body) internal pure returns (BringHomeMessage memory) {
        return abi.decode(body, (BringHomeMessage));
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
