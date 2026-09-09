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

interface ITREXMessaging {

    /// @dev Points this token at the network's vetted gateway set.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - `registry` must not be the zero address; otherwise reverts with `ZeroAddress`.
    ///
    /// Emits `TrustedGatewayRegistrySet`.
    /// @param registry The `TrustedGatewayRegistry` to resolve gateway trust against.
    function setTrustedGatewayRegistry(address registry) external;

    /// @dev Routes this token's traffic to and from a chain through `gateway`.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - A registry must be set; otherwise reverts with `RegistryNotSet`.
    /// - `gateway` must be registry-trusted or zero; otherwise reverts with `GatewayNotTrusted`.
    /// - `chainReference` must be non-empty, with no leading zero byte on EVM; otherwise reverts with
    ///   `InvalidChainReference`.
    ///
    /// Emits `ChainRegistered` on first sight of the prefix, then `RouteSet`.
    /// @param chainType The ERC-7930 chain type, `0x0000` for EVM.
    /// @param chainReference The ERC-7930 chain reference, the minimal big-endian chain id on EVM.
    /// @param gateway The trusted gateway to route through, or zero to close the chain.
    function setRoute(bytes2 chainType, bytes calldata chainReference, address gateway) external;

    /// @dev Registers this token's Lite on `chainKey`: the outbound recipient and the only accepted
    /// inbound author for that chain.
    ///
    /// Only needed off EVM, or when the Lite is not at the token's own address. Empty restores the default.
    ///
    /// Requirements:
    /// - The caller must hold the role bound to this selector by the AccessManager.
    /// - A non-empty `peer` must be a canonical ERC-7930 v1 address with an account part and no
    ///   trailing bytes; otherwise reverts with `InvalidPeer`.
    /// - Its chain prefix must hash to `chainKey`; otherwise reverts with `PeerChainMismatch`.
    ///
    /// Emits `ChainRegistered` on first sight of the prefix, then `PeerSet`.
    /// @param chainKey `keccak256(chainType, chainReference)` of the peer's chain.
    /// @param peer The Lite as an ERC-7930 address, or empty to restore the default.
    function setPeer(bytes32 chainKey, bytes calldata peer) external;

    /// @dev The gateway registry this token resolves trust against.
    /// @return The registry address, or zero when unset.
    function trustedGatewayRegistry() external view returns (address);

    /// @dev The stored route for `chainKey`, not re-validated: the gateway may have been untrusted
    /// since. Use `isChainOpen` to know whether it can carry traffic.
    /// @param chainKey The chain to look up.
    /// @return The routed gateway, or zero when the chain is closed.
    function routeFor(bytes32 chainKey) external view returns (address);

    /// @dev The ERC-7930 prefix recorded for `chainKey`.
    /// @param chainKey The chain to look up.
    /// @return chainType The recorded chain type.
    /// @return chainReference The recorded chain reference, empty when the chain was never seen.
    function chainOf(bytes32 chainKey) external view returns (bytes2 chainType, bytes memory chainReference);

    /// @dev This token's peer on `chainKey`: the registered one, else the token's own address on a
    /// known EVM chain, else empty.
    /// @param chainKey The chain to look up.
    /// @return The peer as an ERC-7930 address, or empty when the chain cannot be addressed.
    function peerFor(bytes32 chainKey) external view returns (bytes memory);

    /// @dev The gateway a validation's leg toward `chainKey` went out through, snapshot at dispatch.
    /// Settlements of that validation from that chain are accepted from this gateway only, so a route
    /// switch affects new validations and never orphans a leg in flight.
    /// @param validationId The validation to look up.
    /// @param chainKey The chain the leg was dispatched toward.
    /// @return The pinned gateway, or zero when the leg never went out.
    function pinnedRouteFor(uint256 validationId, bytes32 chainKey) external view returns (address);

    /// @dev Whether `chainKey` can carry traffic right now: a route, a peer, and a still-trusted gateway.
    /// Re-reads the registry, so an emergency gateway removal closes every chain routed through it.
    /// @param chainKey The chain to check.
    /// @return True when a message can be sent to, and accepted from, that chain.
    function isChainOpen(bytes32 chainKey) external view returns (bool);

}
