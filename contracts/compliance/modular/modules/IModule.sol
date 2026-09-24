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

/// @title IModule
/// @dev Everything a compliance module implements. One interface, no sub-interfaces, no bitmask.
///
/// A module says what it is through {moduleTypes}, read once at binding, and the compliance calls it only
/// where it said so:
/// - `RULE`: asked {allowedAmount}, the largest amount it allows; the compliance takes the minimum;
/// - `SPENDER`: asked {moduleCheckSpender}, whether an operator may spend on a holder's behalf;
/// - `TRACKER`: told {moduleTransferAction}, {moduleMintAction} or {moduleBurnAction} after the ledger moved.
///
/// A module never calls another module. It reads the compliance's ledger ({IComplianceLedger}: position and
/// pending amounts per identity) and the token's identity registry, and keeps nothing but its own settings
/// and its own counters.
///
/// Reserve before calling out. A module that accumulates state in its own storage (a per-period counter, a
/// window) must record the amount BEFORE it makes any external call, and rely on transaction rollback to undo
/// that record if the operation later fails. The token wraps each operation in a reentrancy guard, so a
/// callback cannot reenter the token itself. That guard does not extend to calls a module makes to other
/// contracts, which is why the discipline is required here rather than assumed from the guard.
interface IModule {

    /// @dev What a module is. A module names one, two or all three, never the same one twice.
    enum ModuleType {
        /// Answers {allowedAmount}.
        RULE,
        /// Answers {moduleCheckSpender}.
        SPENDER,
        /// Is told {moduleTransferAction}, {moduleMintAction} and {moduleBurnAction}.
        TRACKER
    }

    /// @dev Everything a module needs to know about a movement, resolved once by the compliance.
    struct TransferContext {
        /// The compliance asking. Modules read the ledger and their settings from it, never from
        /// `msg.sender`, so that tooling can ask the same question from any address.
        address compliance;
        /// Identity of the sender. Zero on a mint.
        address fromIdentity;
        /// Identity of the recipient. Zero on a burn.
        address toIdentity;
        /// Canonical key of the sending wallet: a native address padded on the left, or `keccak256` of a
        /// satellite envelope. Zero on a mint.
        bytes32 fromWallet;
        /// Canonical key of the receiving wallet. Zero on a burn.
        bytes32 toWallet;
        /// Inclusive lower bound of the movement. Equal to `amountMax` on a native movement.
        uint256 amountMin;
        /// Inclusive upper bound: the exact amount on a native movement, the requested maximum, already
        /// capped at what the sending wallet holds, on an issuance.
        uint256 amountMax;
        /// True while a validation is being issued for a satellite movement.
        bool isIssuance;
    }

    /**
     *  @dev binds the module to a compliance contract
     *  once the module is bound, the compliance contract can interact with the module
     *  this function can be called ONLY by the compliance contract itself (_compliance), through the
     *  addModule function, which calls bindCompliance
     *  the module cannot be already bound to the compliance
     *  @param _compliance address of the compliance contract
     *  Emits a ComplianceBound event
     */
    function bindCompliance(address _compliance) external;

    /**
     *  @dev unbinds the module from a compliance contract
     *  once the module is unbound, the compliance contract cannot interact with the module anymore
     *  this function can be called ONLY by the compliance contract itself (_compliance), through the
     *  removeModule function, which calls unbindCompliance
     *  @param _compliance address of the compliance contract
     *  Emits a ComplianceUnbound event
     */
    function unbindCompliance(address _compliance) external;

    /**
     *  @dev the ledger moved between two wallets. Called on every `TRACKER` module after the compliance
     *  updated the positions, on a native transfer, a forced transfer, a recovery and a settled validation
     *  reverting stops the movement: a module that cannot record a move has to stop it. `forceRemoveModule`
     *  is the escape hatch for a module that reverts everywhere
     *  This function can be called ONLY by the compliance contract itself
     *  @param ctx the movement, see {TransferContext}; `amountMin == amountMax == _value`
     *  @param _value the exact amount moved
     */
    function moduleTransferAction(TransferContext calldata ctx, uint256 _value) external;

    /**
     *  @dev tokens were minted. Called on every `TRACKER` module after the compliance updated the position
     *  `ctx.fromIdentity` and `ctx.fromWallet` are zero
     *  This function can be called ONLY by the compliance contract itself
     *  @param ctx the movement, see {TransferContext}
     *  @param _value the amount minted
     */
    function moduleMintAction(TransferContext calldata ctx, uint256 _value) external;

    /**
     *  @dev tokens were burned. Called on every `TRACKER` module after the compliance updated the position
     *  `ctx.toIdentity` and `ctx.toWallet` are zero
     *  This function can be called ONLY by the compliance contract itself
     *  @param ctx the movement, see {TransferContext}
     *  @param _value the amount burned
     */
    function moduleBurnAction(TransferContext calldata ctx, uint256 _value) external;

    /**
     *  @dev the largest amount this rule allows to move. Called on every `RULE` module, on a native transfer
     *  and a mint (`canTransfer`) and on the issuance of a validation (`ctx.isIssuance` set)
     *  the compliance takes the minimum over the declaring modules: a native movement passes when `amountMax`
     *  is at most that minimum; an issuance narrows its range to `[amountMin, minimum]`
     *  `type(uint256).max` means no limit, 0 means refused
     *  the rule has to be monotonic: a smaller amount is never less acceptable than a larger one. A rule that
     *  is not (a multiple of some unit, for instance) evaluates `ctx.amountMax` and returns `max` or 0, and
     *  refuses an issuance whose range is not a point (`ctx.amountMin != ctx.amountMax`), since the satellite
     *  may execute any amount inside the range
     *  identities arrive resolved and the ledger describes the state before the move
     *  a native movement between two wallets of one identity (`ctx.fromIdentity == ctx.toIdentity`, non-zero)
     *  reaches this function and a rule about distribution answers `max` on it; the issuance of such a
     *  movement does not, because it changes no position
     *  MUST be a view: the compliance calls it under `staticcall` and a module that writes there reverts
     *  @param ctx the movement, see {TransferContext}
     *  @return the largest amount allowed
     */
    function allowedAmount(TransferContext calldata ctx) external view returns (uint256);

    /**
     *  @dev whether `_spender` may move `_value` from `_from` to `_to`. Called on every `SPENDER` module from
     *  `canSpenderCall`, which the token runs before spending an allowance in `transferFrom`
     *  all declaring modules must agree. A direct transfer never reaches this path: the spender is the sender
     *  wallets arrive unresolved, as the token knows them, since a spender policy is about who calls, not about
     *  how the tokens are distributed
     *  @param _spender address initiating the transfer on behalf of `_from`
     *  @param _from address the tokens are taken from
     *  @param _to address the tokens are sent to
     *  @param _value amount of tokens moved
     *  @param _compliance address of the compliance asking, which the module keys its settings by
     *  @return true if the module allows the spender to call, false otherwise
     */
    function moduleCheckSpender(address _spender, address _from, address _to, uint256 _value, address _compliance)
        external
        view
        returns (bool);

    /**
     *  @dev what this module is, see {ModuleType}
     *  the compliance reads it once, at binding, and routes the module accordingly. A module that names none
     *  is refused, and so is one naming the same type twice
     *  MUST be pure: a value read from storage would let the recorded routing drift from the real behaviour
     *  @return the types this module implements
     */
    function moduleTypes() external pure returns (ModuleType[] memory);

    /**
     *  @dev getter for compliance binding status on module
     *  @param _compliance address of the compliance contract
     */
    function isComplianceBound(address _compliance) external view returns (bool);

    /**
     *  @dev checks whether compliance is suitable to bind to the module.
     *  @param _compliance address of the compliance contract
     */
    function canComplianceBind(address _compliance) external view returns (bool);

    /**
     *  @dev getter for module plug & play status
     */
    function isPlugAndPlay() external pure returns (bool);

    /**
     *  @dev getter for the name of the module
     *  @return _name the name of the module
     */
    function name() external pure returns (string memory _name);

}
