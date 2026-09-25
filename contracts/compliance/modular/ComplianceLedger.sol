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
 * The registry can change who owns a wallet under the ledger's feet: an agent relinks a local entry, or deletes
 * it. The ledger keeps up on its own. It remembers which identity it credited each native wallet to, and the
 * next movement through that wallet notices the registry now names someone else and moves the wallet's balance
 * to them first, so no owner call is needed. When the registry names nobody, the remembered owner still
 * answers. Satellite wallets need none of this: the IdentityFactory's bindings are sticky.
 *
 * One rule decides what happens when a write still cannot be honoured. The compliance's own bookkeeping, the
 * pending amounts it reserves and releases, uses checked arithmetic and reverts: an inconsistency there is a
 * bug in this contract. A position write that finds nobody, a wallet the ledger never credited and the registry
 * does not know, never reverts, because blocking the movement would make the repair harder. The amount is
 * counted in `gap`, signed, so that `sum(positions) + gap == totalSupply` holds regardless, and `fixPosition`
 * lets the owner move it to where it belongs.
 */
abstract contract ComplianceLedger is IComplianceLedger {

    /// @custom:storage-location erc7201:erc3643.storage.ComplianceLedger
    struct Ledger {
        /// What each identity owns over every wallet and every chain.
        mapping(address identity => uint256 amount) position;
        /// What open validations promise to each identity.
        mapping(address identity => uint256 amount) pendingIn;
        /// What open validations promise out of each identity.
        mapping(address identity => uint256 amount) pendingOut;
        /// What open validations may still draw from each satellite wallet.
        mapping(bytes32 walletKey => uint256 amount) pendingOutOfWallet;
        /// The gap between the positions and the supply: credits that landed on nobody add to it,
        /// debits that found nobody or found too little subtract from it. Zero while the registry is stable.
        int256 gap;
        /// The identity each native wallet was last credited to, so a relink is noticed and followed.
        mapping(address wallet => address identity) ownerOf;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.ComplianceLedger")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant LEDGER_STORAGE_LOCATION =
        0x37065f79446a9096383af794d27f19e665b7dd5afcf9e812ca702bcc08bee600;

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
    function pendingOutOfWallet(bytes32 walletKey) external view returns (uint256) {
        return _ledger().pendingOutOfWallet[walletKey];
    }

    /// @inheritdoc IComplianceLedger
    function ownerOf(address wallet) external view returns (address) {
        return _ledger().ownerOf[wallet];
    }

    /// @inheritdoc IComplianceLedger
    function positionGap() external view returns (int256) {
        return _ledger().gap;
    }

    /// @dev Who a native wallet's tokens belong to now, given who the registry names. Records the first owner
    ///  seen, follows a change of owner, and keeps the remembered owner when the registry names nobody.
    /// @return owner the identity to debit or credit for this wallet
    /// @return previous the identity that was credited before, when the owner just changed and the wallet's
    ///  balance has to follow; zero otherwise
    function _followOwner(address wallet, address resolved) internal returns (address owner, address previous) {
        mapping(address => address) storage ownerOf = _ledger().ownerOf;
        address recorded = ownerOf[wallet];
        if (resolved == address(0)) return (recorded, address(0));
        if (recorded == resolved) return (resolved, address(0));
        ownerOf[wallet] = resolved;
        return (resolved, recorded);
    }

    /// @dev Moves what `wallet` held from the identity it was credited to onto the one the registry names now.
    function _moveWalletBalance(address wallet, address previous, address owner, uint256 balance) internal {
        if (balance != 0) {
            _debitPosition(previous, bytes32(uint256(uint160(wallet))), balance);
            _creditPosition(owner, bytes32(uint256(uint160(wallet))), balance);
        }
        emit EventsLib.WalletOwnerChanged(wallet, previous, owner, balance);
    }

    /// @dev Moves `amount` of position from one side to the other. A zero side is the gap between the positions and
    ///  the supply, so this can give tokens that landed on nobody their owner, or take a stale position off an
    ///  identity a relink left too high.
    function _fixPosition(address from, address to, uint256 amount) internal {
        require(from != to, ErrorsLib.FromAndToAreTheSame());
        Ledger storage ledger = _ledger();

        if (from == address(0)) {
            ledger.gap -= int256(amount);
        } else {
            uint256 held = ledger.position[from];
            require(held >= amount, ErrorsLib.InsufficientPosition(from, held, amount));
            ledger.position[from] = held - amount;
        }

        if (to == address(0)) ledger.gap += int256(amount);
        else ledger.position[to] += amount;

        emit EventsLib.PositionFixed(from, to, amount);
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
        Ledger storage ledger = _ledger();
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
        Ledger storage ledger = _ledger();
        if (identity == address(0)) {
            ledger.gap += int256(amount);
            emit EventsLib.PositionUnresolved(wallet, amount);
            return;
        }
        ledger.position[identity] += amount;
    }

    /// @dev Counts an issued validation as pending at `amountMax`, the worst case for any additive rule.
    ///
    ///  A reservation has two halves, and they are released at different moments, which is why the release
    ///  is two functions and this returns which halves it wrote:
    ///  - the wallet's half is always written, and caps what a further validation may draw from that wallet;
    ///  - the identities' half is written only when ownership really moves, so relocating tokens between two
    ///    wallets of one identity never eats that identity's own room.
    /// @return identitiesReserved whether the identities' half was written, which the caller records on the
    ///  validation so the release undoes exactly what this wrote
    function _reservePending(address fromIdentity, address toIdentity, bytes32 fromWallet, uint256 amountMax)
        internal
        returns (bool identitiesReserved)
    {
        Ledger storage ledger = _ledger();
        ledger.pendingOutOfWallet[fromWallet] += amountMax;
        if (_isRelocation(fromIdentity, toIdentity)) return false;
        ledger.pendingOut[fromIdentity] += amountMax;
        ledger.pendingIn[toIdentity] += amountMax;
        return true;
    }

    /// @dev Undoes the identities' half of {_reservePending}, once the movement is over: the validation
    ///  settled, or the keeper discarded it.
    function _releasePendingOfIdentities(address fromIdentity, address toIdentity, uint256 amountMax) internal {
        Ledger storage ledger = _ledger();
        ledger.pendingOut[fromIdentity] -= amountMax;
        ledger.pendingIn[toIdentity] -= amountMax;
    }

    /// @dev Undoes the wallet's half of {_reservePending}. It is released earlier than the identities' half
    ///  when a burn leg lands first: that leg is proof the wallet's tokens are already gone, so nothing more
    ///  can be drawn from it, while the identities' half waits for the movement to complete.
    function _releasePendingOfWallet(bytes32 walletKey, uint256 amountMax) internal {
        _ledger().pendingOutOfWallet[walletKey] -= amountMax;
    }

    /// @dev One identity on both sides. Two wallets that resolve to nobody are not that.
    function _isRelocation(address fromIdentity, address toIdentity) internal pure returns (bool) {
        return fromIdentity != address(0) && fromIdentity == toIdentity;
    }

    function _ledger() internal pure returns (Ledger storage ledger) {
        assembly ("memory-safe") {
            ledger.slot := LEDGER_STORAGE_LOCATION
        }
    }

}
