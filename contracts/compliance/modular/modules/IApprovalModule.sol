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

import { IModule } from "./IModule.sol";

/**
 * @title IApprovalModule
 * @dev What a module naming `APPROVAL` adds to {IModule}. While one is bound, a cross-chain request is not
 * issued at once: the compliance records and reserves it as `AwaitingApproval`, tells this module, and waits for
 * `answerApproval`. Who decides, how many decide and in which order is the module's own business.
 */
interface IApprovalModule {

    /// @dev A validation was requested and waits for this module's answer. Called by the compliance inside
    ///  `requestTransferValidation`, once the range was narrowed by every rule and reserved; reverting refuses
    ///  the request. The module answers later, before `deadline`, with `answerApproval` on the compliance; it
    ///  may also answer at once, from inside this call, since the validation is already `AwaitingApproval`.
    /// @param validationId the validation awaiting approval
    /// @param ctx the movement, as the rules saw it at the request, with the narrowed range
    /// @param deadline the last moment, exclusive, an answer from this module is taken
    function approvalRequested(bytes32 validationId, IModule.TransferContext calldata ctx, uint64 deadline) external;

}
