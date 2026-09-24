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
    ///  A wallet that resolves to no identity, which only a registry unlink can produce, has no position to
    ///  debit, and a debit larger than the position floors at zero. Both are reported and neither reverts:
    ///  the cause is outside this contract, and blocking a burn or a forced transfer would make the repair
    ///  harder rather than safer.
    function _debitPosition(address identity, bytes32 wallet, uint256 amount) private {
        if (identity == address(0)) {
            emit EventsLib.PositionUnresolved(wallet, amount);
            return;
        }
        mapping(address => uint256) storage position = _ledger().position;
        uint256 held = position[identity];
        if (held < amount) {
            emit EventsLib.PositionUnderflow(identity, amount - held);
            position[identity] = 0;
            return;
        }
        position[identity] = held - amount;
    }

    /// @dev Adds `amount` to an identity's position. A wallet that resolves to no identity is reported, as in
    ///  {_debitPosition}, and credited to nobody.
    function _creditPosition(address identity, bytes32 wallet, uint256 amount) private {
        if (identity == address(0)) {
            emit EventsLib.PositionUnresolved(wallet, amount);
            return;
        }
        _ledger().position[identity] += amount;
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

    /// @dev The id a native wallet has in the ledger and in a module's context: its address padded on the left.
    function _walletKeyOf(address wallet) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(wallet)));
    }

    function _ledger() internal pure returns (Ledger storage ledger) {
        assembly ("memory-safe") {
            ledger.slot := LEDGER_STORAGE_LOCATION
        }
    }

}
