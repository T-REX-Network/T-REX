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

import { EventsLib } from "../../libraries/EventsLib.sol";
import { ComplianceLedgerLib } from "./ComplianceLedgerLib.sol";
import { IComplianceLedger } from "./IComplianceLedger.sol";

/**
 * @title ComplianceLedger
 * @dev The four numbers the compliance keeps about identities, in its own ERC-7201 namespace.
 *
 * The rule: a number is kept by the contract that produces it. The compliance sees every movement through the
 * token's hooks and issues every cross-chain validation itself, so it is the one contract that can keep an
 * identity's total and its outstanding promises. Modules read them and keep none of their own.
 *
 * Only this contract writes them, from the hooks and from the issuance, settlement and discard paths. There is
 * no setter, no writer role and no key: four mappings and four views.
 *
 * Registry writes never move a wallet to another identity. Its owner can still change when the owner swaps the
 * registry's storage, or unbinds a registry from that storage. The ledger follows the registry so that rules
 * and positions always agree. It remembers which identity it credited each native wallet to, and the next
 * movement through that wallet moves the wallet's balance to the identity the registry names now. When the
 * registry names nobody, the remembered owner still answers. Satellite wallets resolve through the
 * IdentityFactory only, so they never change owner.
 *
 * Every token has an owner: the registry admits no wallet without an active identity, even with its
 * eligibility checks disabled, and each native wallet's balance is always counted under its recorded owner.
 * So `sum(positions) == totalSupply` always holds, and every write uses checked arithmetic: a debit the
 * position cannot cover is a bug in this contract, and reverts.
 *
 * Nothing repairs a position. A debit that reverts means the invariant is broken, so the agent's own calls on
 * that identity (burn, forced transfer, recovery) revert with it. The fix is a compliance implementation upgrade
 * through the version manager, not an owner call.
 */
abstract contract ComplianceLedger is IComplianceLedger {

    /// @inheritdoc IComplianceLedger
    function positionOf(address identity) external view returns (uint256) {
        return _ledger().position[identity];
    }

    /// @inheritdoc IComplianceLedger
    function pendingInOf(address identity) external view returns (uint256) {
        return _ledger().pendingIn[identity];
    }

    /// @inheritdoc IComplianceLedger
    function pendingOutOf(address identity) external view returns (uint256) {
        return _ledger().pendingOut[identity];
    }

    /// @inheritdoc IComplianceLedger
    function ownerOf(address wallet) external view returns (address) {
        return _ledger().ownerOf[wallet];
    }

    /// @dev Who a native wallet's tokens belong to now, given who the registry names. Records the first owner
    ///  seen, follows a change of owner, and keeps the remembered owner when the registry names nobody.
    /// @return owner the identity to debit or credit for this wallet
    /// @return previous the identity that was credited before, when the owner just changed and the wallet's
    ///  balance has to follow; zero otherwise
    function _followOwner(address wallet, address resolved) internal returns (address owner, address previous) {
        ComplianceLedgerLib.Ledger storage ledger = _ledger();
        address recorded = ledger.ownerOf[wallet];
        if (resolved == address(0)) return (recorded, address(0));
        if (recorded == resolved) return (resolved, address(0));
        ledger.ownerOf[wallet] = resolved;
        return (resolved, recorded);
    }

    /// @dev Moves what `wallet` held from the identity it was credited to onto the one the registry names now.
    function _moveWalletBalance(address wallet, address previous, address owner, uint256 balance) internal {
        if (balance != 0) {
            ComplianceLedgerLib.Ledger storage ledger = _ledger();
            ledger.position[previous] -= balance;
            ledger.position[owner] += balance;
        }
        emit EventsLib.WalletOwnerChanged(wallet, previous, owner, balance);
    }

    /// @dev Moves `amount` of position from one identity to the other: one side loses it, the other gains it.
    ///
    ///  A relocation between two wallets of one identity is not a change of ownership, so nothing moves.
    ///  A zero wallet is the absent side of a mint or a burn, and is simply skipped.
    function _movePosition(
        address fromIdentity,
        address toIdentity,
        bytes32 fromWallet,
        bytes32 toWallet,
        uint256 amount
    ) internal {
        if (_isRelocation(fromIdentity, toIdentity)) return;
        ComplianceLedgerLib.Ledger storage ledger = _ledger();
        if (fromWallet != bytes32(0)) ledger.position[fromIdentity] -= amount;
        if (toWallet != bytes32(0)) ledger.position[toIdentity] += amount;
    }

    /// @dev Undoes the identities' half of {ComplianceLedgerLib-reservePending}, once the movement is over: the validation
    ///  settled, or the keeper discarded it.
    function _releasePendingOfIdentities(address fromIdentity, address toIdentity, uint256 amountMax) internal {
        ComplianceLedgerLib.Ledger storage ledger = _ledger();
        ledger.pendingOut[fromIdentity] -= amountMax;
        ledger.pendingIn[toIdentity] -= amountMax;
        ledger.pendingTotal -= amountMax;
    }

    /// @dev See {ComplianceLedgerLib-isRelocation}.
    function _isRelocation(address fromIdentity, address toIdentity) internal pure returns (bool) {
        return ComplianceLedgerLib.isRelocation(fromIdentity, toIdentity);
    }

    function _ledger() internal pure returns (ComplianceLedgerLib.Ledger storage) {
        return ComplianceLedgerLib.layout();
    }

}
