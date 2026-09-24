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

import { ErrorsLib } from "../../../libraries/ErrorsLib.sol";
import {
    AccessManagedOwnableBase,
    AccessManagedOwnableUpgradeable
} from "../../../utils/AccessManagedOwnableUpgradeable.sol";
import { IComplianceLedger } from "../IComplianceLedger.sol";
import { AbstractModuleUpgradeable } from "./AbstractModuleUpgradeable.sol";
import { IModule } from "./IModule.sol";

/// @title MaxBalancePerIdentityModule
/// @dev Caps what one identity may own, over every wallet and every chain, per compliance.
///
/// The rule keeps nothing but its cap. The position and the pending amounts it decides from are the
/// compliance's own numbers, so it works natively and cross-chain with one function: a native transfer, a
/// validation issuance, two validations racing for the same cap and a late reconciliation are all the same
/// question. It needs no preset before binding to a live token, since the compliance already keeps every
/// position.
contract MaxBalancePerIdentityModule is AbstractModuleUpgradeable, AccessManagedOwnableUpgradeable {

    /// @custom:storage-location erc7201:erc3643.storage.MaxBalancePerIdentityModule
    struct MaxBalanceStorage {
        /// Zero means the cap was never set, which refuses every acquisition: bind with `addAndSetModule`.
        mapping(address compliance => uint256) maxBalance;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.MaxBalancePerIdentityModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _MAX_BALANCE_STORAGE_LOCATION =
        0xb46b06d4ef5f052799f86ec8b39b25cbd5647dec9a0f243c659eefdabbf28400;

    event MaxBalanceSet(address indexed compliance, uint256 maxBalance);

    constructor() {
        _disableInitializers();
    }

    /// @dev Initializes the module behind its proxy.
    /// @param accessManagerAddress authority gating the implementation upgrade
    function initialize(address accessManagerAddress) external initializer {
        require(accessManagerAddress != address(0), ErrorsLib.ZeroAddress());

        __AbstractModule_init();
        __AccessManaged_init(accessManagerAddress);
    }

    /// @dev Sets the cap for the calling compliance. Emits `MaxBalanceSet`.
    /// @param _max the largest position one identity may own
    function setMaxBalance(uint256 _max) external onlyComplianceCall {
        _getMaxBalanceStorage().maxBalance[msg.sender] = _max;
        emit MaxBalanceSet(msg.sender, _max);
    }

    /// @dev The cap configured for `_compliance`.
    function maxBalanceOf(address _compliance) external view returns (uint256) {
        return _getMaxBalanceStorage().maxBalance[_compliance];
    }

    /// @inheritdoc IModule
    /// @dev The room left under the cap for the recipient: the cap less what the identity owns and what is
    ///  already promised to it by validations that have not settled. No limit on a burn or on a relocation
    ///  between one identity's wallets, which changes no position.
    function allowedAmount(TransferContext calldata ctx) external view override returns (uint256) {
        if (ctx.toIdentity == address(0) || ctx.fromIdentity == ctx.toIdentity) return type(uint256).max;
        IComplianceLedger ledger = IComplianceLedger(ctx.compliance);
        uint256 held = ledger.positionOf(ctx.toIdentity) + ledger.pendingInOf(ctx.toIdentity);
        uint256 cap = _getMaxBalanceStorage().maxBalance[ctx.compliance];
        return held >= cap ? 0 : cap - held;
    }

    /// @inheritdoc IModule
    function moduleTypes() external pure returns (ModuleType[] memory types) {
        types = new ModuleType[](1);
        types[0] = ModuleType.RULE;
    }

    /// @inheritdoc IModule
    /// @dev Binds anywhere. The compliance keeps every position from the token's first mint, so there is
    ///  nothing to set up first.
    function isPlugAndPlay() external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IModule
    function canComplianceBind(address) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IModule
    function name() external pure returns (string memory) {
        return "MaxBalancePerIdentityModule";
    }

    /// @dev See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AbstractModuleUpgradeable, AccessManagedOwnableBase)
        returns (bool)
    {
        return AbstractModuleUpgradeable.supportsInterface(interfaceId)
            || AccessManagedOwnableBase.supportsInterface(interfaceId);
    }

    /// @dev Only the configured AccessManager role may upgrade the implementation.
    function _authorizeUpgrade(address) internal override restricted { }

    function _getMaxBalanceStorage() private pure returns (MaxBalanceStorage storage $) {
        assembly ("memory-safe") {
            $.slot := _MAX_BALANCE_STORAGE_LOCATION
        }
    }

}
