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

pragma solidity ^0.8.30;

pragma solidity 0.8.30;

import { ErrorsLib } from "./ErrorsLib.sol";

/**
 * @title MessageTypesLib
 * @dev The protocol's ERC-7786 message surface: the four types that cross the interop boundary, the
 * bodies they carry, and the envelope that wraps them.
 */
library MessageTypesLib {

    /// @dev Outbound. A `ComplianceValidation` issued on the reference chain for a satellite to execute.
    uint8 internal constant COMPLIANCE_VALIDATION = 1;

    /// @dev Outbound. A delegation-out instruction to mint on a satellite. One-way, nothing reconciled.
    uint8 internal constant MINT_INSTRUCTION = 2;

    /// @dev Inbound. A satellite reporting that a validation's leg executed.
    uint8 internal constant SETTLEMENT_NOTIFICATION = 3;

    /// @dev Inbound. A satellite's proof that it burned a position, so a recall can credit the holder.
    uint8 internal constant BURN_PROOF = 4;

    /// @dev The envelope version this library serves. A payload carrying any other version is refused.
    uint8 internal constant VERSION = 1;

    /// @dev The ERC-7930 chain type of every EVM chain, where CREATE3 puts a Lite at its token's own address.
    bytes2 internal constant EVM_CHAIN_TYPE = 0x0000;

    /// @dev EIP-712 type hash of `ComplianceValidation`:
    ///  keccak256("ComplianceValidation(uint256 validationId,bytes from,bytes to,bytes spender,uint256 amountMin,
    ///  uint256 amountMax,address token,uint64 expiry,uint64 reconciliationWindow)")
    bytes32 internal constant COMPLIANCE_VALIDATION_TYPEHASH =
        0x0b9e295f943ccd7dad6f3ca3f907365ba5866f07431e165136759414e1e5f9f6;

    /// @dev Body of a `COMPLIANCE_VALIDATION`: the reference chain's authorization for one movement, consumed by
    /// T-REX Lite on the involved chain or chains. A satellite executes a transfer only against this object.
    struct ComplianceValidation {
        /// Unique per compliance contract, single-use: the satellite records it as consumed, T-REX keys the slot on it.
        uint256 validationId;
        /// ERC-7930 interoperable address of the sender, carrying its own chain reference.
        bytes from;
        /// ERC-7930 interoperable address of the recipient. Equal chain references with `from` mean a same-chain
        /// transfer, different ones a burn on `from`'s chain and a mint on `to`'s.
        bytes to;
        /// ERC-7930 interoperable address allowed to execute through `transferFrom`; empty means only `from` may execute.
        bytes spender;
        /// Inclusive lower bound of the executed amount: caller-proposed, engine-narrowed.
        uint256 amountMin;
        /// Inclusive upper bound of the executed amount: caller-proposed, engine-narrowed, capped at `from`'s balance.
        uint256 amountMax;
        /// The asset's address on the T-REX reference chain, its canonical identifier on every chain.
        address token;
        /// Absolute timestamp: the satellite executes strictly before it, never at or after.
        uint64 expiry;
        /// Seconds T-REX keeps the compliance slot reserved past `expiry`, waiting for the reconciliation.
        uint64 reconciliationWindow;
    }

    /// @dev Body of a `SETTLEMENT_NOTIFICATION`: a satellite reporting that one leg of a validation executed.
    struct SettlementNotification {
        uint256 validationId;
        /// Canonical reference-chain asset address, must match the validation.
        address token;
        /// ERC-7930; empty on the mint leg.
        bytes from;
        /// ERC-7930; empty on the burn leg.
        bytes to;
        uint256 amount;
    }

    /// @dev Body of a `BURN_PROOF`: a satellite's proof that it burned a position, so a recall can credit
    /// the holder on the reference chain.
    struct BurnProof {
        /// ERC-7930 wallet the satellite burned.
        bytes burnedWallet;
        uint256 amount;
        /// Reference-chain wallet to credit as free balance. Must be linked to the same identity as`burnedWallet`.
        address nativeWallet;
    }

    /// @dev Wraps `body` in the envelope. Reverts on a type this library does not define.
    function encode(uint8 messageType, bytes memory body) internal pure returns (bytes memory) {
        require(isKnownType(messageType), ErrorsLib.UnknownMessageType(messageType));
        return abi.encode(messageType, VERSION, body);
    }

    /// @dev Unwraps an envelope into its type and its untouched body.
    ///
    /// Refuses an undefined type and an unserved version before the body is ever looked at, so an
    /// unrecognised message can never reach a handler.
    function decode(bytes memory payload) internal pure returns (uint8 messageType, bytes memory body) {
        uint8 messageVersion;
        (messageType, messageVersion, body) = abi.decode(payload, (uint8, uint8, bytes));

        require(isKnownType(messageType), ErrorsLib.UnknownMessageType(messageType));
        require(messageVersion == VERSION, ErrorsLib.UnsupportedMessageVersion(messageVersion));
    }

    /// @dev EIP-712 `hashStruct` of a validation, without a domain: the satellite and the slot lifecycle use it as
    /// the identifier of the object, not as something to sign. Dynamic `bytes` members hash to their `keccak256`,
    /// static members encode in place.
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
        return abi.encode(COMPLIANCE_VALIDATION, VERSION, abi.encode(validation));
    }

    /// @dev Unwraps a `COMPLIANCE_VALIDATION` body. Reverts on a body that is not one.
    function decodeValidation(bytes memory body) internal pure returns (ComplianceValidation memory) {
        return abi.decode(body, (ComplianceValidation));
    }

    /// @dev Wraps a settlement notification in the envelope, as a satellite's Lite does before sending.
    function encodeSettlement(SettlementNotification memory notification) internal pure returns (bytes memory) {
        return abi.encode(SETTLEMENT_NOTIFICATION, VERSION, abi.encode(notification));
    }

    /// @dev Unwraps a `SETTLEMENT_NOTIFICATION` body. Reverts on a body that is not one.
    function decodeSettlement(bytes memory body) internal pure returns (SettlementNotification memory) {
        return abi.decode(body, (SettlementNotification));
    }

    /// @dev Wraps a burn proof in the envelope, as a satellite's Lite does before sending.
    function encodeBurnProof(BurnProof memory proof) internal pure returns (bytes memory) {
        return abi.encode(BURN_PROOF, VERSION, abi.encode(proof));
    }

    /// @dev Unwraps a `BURN_PROOF` body. Reverts on a body that is not one.
    function decodeBurnProof(bytes memory body) internal pure returns (BurnProof memory) {
        return abi.decode(body, (BurnProof));
    }

    /// @dev Whether `messageType` is one of the four this surface defines.
    function isKnownType(uint8 messageType) internal pure returns (bool) {
        return messageType >= COMPLIANCE_VALIDATION && messageType <= BURN_PROOF;
    }

    /// @dev The per-chain key every route, peer and per-chain setting is stored under.
    ///
    /// Hashes the ERC-7930 chain prefix, so one key covers a chain whatever address it is paired with.
    function chainKey(bytes2 chainType, bytes memory chainReference) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(chainType, chainReference));
    }

}
