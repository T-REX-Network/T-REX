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

import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
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
 * A wallet's owner is recorded the first time the ledger sees it and never changes. The registry could still
 * name another identity later, for example after its storage is swapped. The ledger then keeps the recorded
 * owner and emits `WalletOwnerMismatch`. If the registry names nobody, the recorded owner is used too.
 *
 * One rule decides what happens when a write still cannot be honoured. The compliance's own bookkeeping, the
 * pending amounts it reserves and releases, uses checked arithmetic and reverts: an inconsistency there is a
 * bug in this contract. A position write that finds nobody, a wallet the ledger never credited and the registry
 * does not know, never reverts, because blocking the movement would make the repair harder. The amount is
 * counted in `gap`, signed, so that `sum(positions) + gap == totalSupply` holds regardless, and `fixPosition`
 * lets the owner move it to where it belongs.
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

    /// @inheritdoc IComplianceLedger
    function positionGap() external view returns (int256) {
        return _ledger().gap;
    }

    /// @dev The identity a native wallet's tokens are counted under. The first identity the registry names is
    ///  recorded and kept for good. If the registry later names another identity, the recorded one is still
    ///  used and `WalletOwnerMismatch` is emitted.
    function _ownerOf(address wallet, address resolved) internal returns (address) {
        mapping(address wallet => address identity) storage owners = _ledger().ownerOf;
        address recorded = owners[wallet];
        if (recorded == address(0)) {
            if (resolved != address(0)) owners[wallet] = resolved;
            return resolved;
        }
        if (resolved != address(0) && resolved != recorded) {
            emit EventsLib.WalletOwnerMismatch(wallet, recorded, resolved);
        }
        return recorded;
    }

    /// @dev Moves `amount` of position from one side to the other. A zero side is the gap between the positions and
    ///  the supply, so this can give tokens that landed on nobody their owner.
    function _fixPosition(address from, address to, uint256 amount) internal {
        ComplianceLedgerLib.fixPosition(from, to, amount);
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
        if (fromWallet != bytes32(0)) _debitPosition(fromIdentity, fromWallet, amount);
        if (toWallet != bytes32(0)) _creditPosition(toIdentity, toWallet, amount);
    }

    /// @dev Takes `amount` off an identity's position.
    ///
    ///  Two things the registry can do leave nothing, or too little, to debit: a wallet that resolves to nobody,
    ///  and an identity relinked to a wallet after another identity's position was credited for it. Neither
    ///  reverts, since the cause is outside this contract and blocking a burn or a forced transfer would make
    ///  the repair harder. What could not be debited leaves the positions over the supply, so it comes off
    ///  the gap, and the event names it for the owner who will `fixPosition` it.
    function _debitPosition(address identity, bytes32 wallet, uint256 amount) private {
        ComplianceLedgerLib.Ledger storage ledger = _ledger();
        if (identity == address(0)) {
            ledger.gap -= int256(amount);
            emit EventsLib.PositionUnresolved(wallet, amount);
            return;
        }
        uint256 held = ledger.position[identity];
        if (held < amount) {
            ledger.gap -= int256(amount - held);
            ledger.position[identity] = 0;
            emit EventsLib.PositionUnderflow(identity, amount - held);
            return;
        }
        ledger.position[identity] = held - amount;
    }

    /// @dev Adds `amount` to an identity's position. A wallet that resolves to nobody is credited to the gap
    ///  instead, which leaves the positions short of the supply by exactly that amount.
    function _creditPosition(address identity, bytes32 wallet, uint256 amount) private {
        ComplianceLedgerLib.Ledger storage ledger = _ledger();
        if (identity == address(0)) {
            ledger.gap += int256(amount);
            emit EventsLib.PositionUnresolved(wallet, amount);
            return;
        }
        ledger.position[identity] += amount;
    }

    /// @dev Undoes the identities' half of {ComplianceLedgerLib-reservePending}, once the movement is over: the validation
    ///  settled, or the keeper discarded it.
    function _releasePendingOfIdentities(address fromIdentity, address toIdentity, uint256 amountMax) internal {
        ComplianceLedgerLib.Ledger storage ledger = _ledger();
        ledger.pendingOut[fromIdentity] -= amountMax;
        ledger.pendingIn[toIdentity] -= amountMax;
    }

    /// @dev See {ComplianceLedgerLib-isRelocation}.
    function _isRelocation(address fromIdentity, address toIdentity) internal pure returns (bool) {
        return ComplianceLedgerLib.isRelocation(fromIdentity, toIdentity);
    }

    function _ledger() internal pure returns (ComplianceLedgerLib.Ledger storage) {
        return ComplianceLedgerLib.layout();
    }

}
