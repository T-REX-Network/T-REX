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

/// @title WalletKeyLib
/// @notice Canonical ERC-7930 handling for the wallet keys of the bridged ledger.
library WalletKeyLib {

    /// @dev version (2) + chainType (2) + chainReference length (1) + address length (1)
    uint256 private constant HEADER_LENGTH = 6;

    /// @dev The ERC-7930 chain type of EVM chains, whose chain reference is the minimal big-endian chain id.
    bytes2 private constant EVM_CHAIN_TYPE = 0x0000;

    /// @notice Parses a version 1 ERC-7930 envelope, requiring it to be canonical.
    /// @dev One encoding per wallet, so one ledger key per wallet. Refused: bytes beyond the parsed envelope
    ///  (ONCHAINID M-08) and a zero-led EVM chain reference, which decodes to the same id. A lone zero byte
    ///  is accepted: it is how OpenZeppelin formats chain id 0.
    /// @param envelope the interoperable address
    /// @return chainType the CAIP-350 chain type
    /// @return chainReference the chain reference bytes
    /// @return addr the address bytes
    function parse(bytes memory envelope)
        internal
        pure
        returns (bytes2 chainType, bytes memory chainReference, bytes memory addr)
    {
        bool success;
        (success, chainType, chainReference, addr) = InteroperableAddress.tryParseV1(envelope);
        require(
            success && HEADER_LENGTH + chainReference.length + addr.length == envelope.length
                && (chainType != EVM_CHAIN_TYPE || chainReference.length < 2 || chainReference[0] != 0x00),
            ErrorsLib.NonCanonicalInteroperableAddress(envelope)
        );
    }

    /// @notice Returns the ledger key of a wallet: `keccak256` over its canonical envelope.
    /// @param envelope the interoperable address
    function canonicalKey(bytes memory envelope) internal pure returns (bytes32 key) {
        parse(envelope);
        assembly ("memory-safe") {
            key := keccak256(add(envelope, 0x20), mload(envelope))
        }
    }

    /// @notice Returns the ledger key of a satellite wallet: a canonical envelope on any chain but this one.
    /// @param envelope the interoperable address
    function satelliteKey(bytes memory envelope) internal view returns (bytes32 key) {
        parse(envelope);
        (bool isEvm, uint256 chainId,) = InteroperableAddress.tryParseEvmV1(envelope);
        require(!isEvm || chainId != block.chainid, ErrorsLib.NotASatelliteWallet(envelope));
        assembly ("memory-safe") {
            key := keccak256(add(envelope, 0x20), mload(envelope))
        }
    }

    /// @notice Tells whether an envelope designates an EVM wallet on this chain.
    /// @param envelope the interoperable address
    /// @return onReferenceChain true when the envelope is a non-zero EVM address on `block.chainid`
    /// @return wallet the unwrapped address, or zero when the envelope is not on this chain
    function isReferenceChain(bytes memory envelope) internal view returns (bool onReferenceChain, address wallet) {
        parse(envelope);
        (bool isEvm, uint256 chainId, address addr) = InteroperableAddress.tryParseEvmV1(envelope);
        onReferenceChain = isEvm && chainId == block.chainid && addr != address(0);
        if (onReferenceChain) wallet = addr;
    }

}
