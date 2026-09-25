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
import { IModule } from "./modules/IModule.sol";

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
    ///  A wallet that resolves to no identity has no position to debit, and a debit larger than the position
    ///  floors at zero. Both are reported and neither reverts: the cause is outside this contract, and blocking
    ///  a burn or a forced transfer would make the repair harder rather than safer.
    ///
    ///  The ledger's numbers are exact on one precondition: every wallet that holds tokens attributes to an
    ///  identity. A revoked wallet still does, so an investor cannot break it. Only a registry agent can, by
    ///  deleting the local entry of a wallet that holds tokens and has no global link; from then on the sum of
    ///  positions is short of the supply by what that wallet moves, and `PositionUnresolved` names the amount.
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

    /// @dev Counts an issued validation as pending at `amountMax`, the worst case for any additive rule. Only
    ///  when ownership really moves: relocating tokens between two wallets of one identity never eats that
    ///  identity's own room. What the sending wallet may still send is the token's to track, beside the balance
    ///  it reserves against.
    /// @return identitiesReserved whether anything was written, which the caller records on the validation
    function _reservePending(address fromIdentity, address toIdentity, bytes32 fromWallet, uint256 amountMax)
        internal
        returns (bool identitiesReserved)
    {
        Ledger storage ledger = _ledger();
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

    /// @dev One identity on both sides. Two wallets that resolve to nobody are not that.
    function _isRelocation(address fromIdentity, address toIdentity) internal pure returns (bool) {
        return fromIdentity != address(0) && fromIdentity == toIdentity;
    }

    /// @dev The id a native wallet has in the ledger and in a module's context: its address padded on the left.
    function _walletIdOf(address wallet) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(wallet)));
    }

    /// @dev Fills the movement every rule and tracker receives. The one place a context is built: the
    ///  compliance's hooks, the issuance and the settlement all come through here, so a module is asked the
    ///  same shape whatever produced the movement. `spender` stays empty; the two callers that have one set
    ///  it afterwards.
    function _buildContext(
        address fromIdentity,
        address toIdentity,
        bytes32 fromWallet,
        bytes32 toWallet,
        uint256 amountMin,
        uint256 amountMax,
        bool isIssuance
    ) internal view returns (IModule.TransferContext memory ctx) {
        ctx.compliance = address(this);
        ctx.fromIdentity = fromIdentity;
        ctx.toIdentity = toIdentity;
        ctx.fromWallet = fromWallet;
        ctx.toWallet = toWallet;
        ctx.amountMin = amountMin;
        ctx.amountMax = amountMax;
        ctx.isIssuance = isIssuance;
    }

    function _ledger() internal pure returns (Ledger storage ledger) {
        assembly ("memory-safe") {
            ledger.slot := LEDGER_STORAGE_LOCATION
        }
    }

}
