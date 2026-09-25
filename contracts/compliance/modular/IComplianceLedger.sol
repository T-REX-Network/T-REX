// SPDX-License-Identifier: GPL-3.0
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

/// @title IComplianceLedger
/// @dev The four numbers the compliance keeps, and the only thing a module reads from it.
///
/// The token knows balances per wallet. One investor holds several wallets, on this chain and on satellites,
/// and every rule about how the asset is distributed asks the same two questions about the investor, not the
/// wallet: how much does this identity own in total, and how much is already promised to or from it by
/// validations that have not settled yet. The compliance is the contract that sees every movement and issues
/// every validation, so it keeps those numbers itself, once, instead of each module rebuilding them.
///
/// Nothing here is written from outside: the compliance updates these from the hooks the token already calls
/// and from its own issuance, settlement and discard paths.
///
/// These numbers are exact on one precondition: every wallet that holds tokens resolves, through the token's
/// identity registry, to the identity that owns it. A wallet keeps resolving after its investor revokes it, so
/// no investor can break this on their own, and a token that circulates may not change its registry or its
/// compliance. What remains is a registry agent deleting or relinking the local entry of a wallet that holds
/// tokens: from then on the position the ledger keeps for that wallet's owner is stale, and the compliance
/// emits `PositionUnresolved` or `PositionUnderflow` naming the amount it could not attribute. A wallet that
/// holds tokens is recovered, never unbound.
interface IComplianceLedger {

    /// @dev What `identity` owns in total: free, frozen and bridged, over every wallet linked to it, revoked
    ///  wallets included. Moving tokens between two wallets of one identity does not change it.
    /// @param identity the ONCHAINID to look up
    function positionOf(address identity) external view returns (uint256);

    /// @dev Sum of `amountMax` over the validations issued toward `identity` that have not settled or been
    ///  discarded. What a cap on acquisitions must count on top of the position.
    /// @param identity the ONCHAINID to look up
    function pendingInOf(address identity) external view returns (uint256);

    /// @dev Sum of `amountMax` over the validations issued out of `identity` that have not settled or been
    ///  discarded. What a floor on holdings must subtract from the position.
    /// @param identity the ONCHAINID to look up
    function pendingOutOf(address identity) external view returns (uint256);

}
